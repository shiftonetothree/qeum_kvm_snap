#!/bin/bash

# --- 1. 展示虚拟机列表 ---
echo "================================================"
echo "🛡️  KVM 虚拟机离线快照清理工具"
echo "================================================"

printf "%-10s %-30s %-10s\n" "ID" "虚拟机名称" "状态"
virsh list --all | sed '1,2d' | awk '{printf "%-10s %-30s %-10s\n", $1, $2, $3}'
echo "------------------------------------------------"

# --- 2. 选择虚拟机并检查状态 ---
while true; do
    read -p "请输入要操作的虚拟机名称: " VM_NAME
    if [[ -z "$VM_NAME" ]]; then continue; fi
    if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        echo "❌ 错误：找不到名为 '$VM_NAME' 的虚拟机。"
    else
        break
    fi
done

VM_STATE=$(virsh domstate "$VM_NAME")
if [ "$VM_STATE" != "shut off" ]; then
    echo "⚠️  当前状态: $VM_STATE"
    echo "❌ 错误：请先关闭虚拟机后再进行快照合并操作。"
    exit 1
fi

# --- 3. 展示快照列表并选择目标 ---
echo ""
echo "📊 该虚拟机的快照链结构："
virsh snapshot-list "$VM_NAME" --tree
echo "------------------------------------------------"

while true; do
    read -p "请输入要【被合并】的快照名称 (及其上方旧快照将被清理): " TARGET_SNAP
    if [[ -z "$TARGET_SNAP" ]]; then continue; fi
    if ! virsh snapshot-info "$VM_NAME" "$TARGET_SNAP" >/dev/null 2>&1; then
        echo "❌ 错误：快照 '$TARGET_SNAP' 不存在。"
    else
        break
    fi
done

# --- 4. 自动定位后续快照 (万能兼容模式) ---
CHILDREN=()
# 获取所有快照名称列表，逐一检查其父节点
ALL_SNAPS=$(virsh snapshot-list "$VM_NAME" --name)

for s in $ALL_SNAPS; do
    # 获取当前快照的父节点
    P=$(virsh snapshot-parent "$VM_NAME" "$s" 2>/dev/null)
    if [[ "$P" == "$TARGET_SNAP" ]]; then
        CHILDREN+=("$s")
    fi
done

# 场景 A: 处理最末端节点 (向后合并)
if [ ${#CHILDREN[@]} -eq 0 ]; then
    # 1. 获取当前物理路径
    TARGET_FILE=$(virsh snapshot-dumpxml "$VM_NAME" "$TARGET_SNAP" | grep "<source file=" | head -n 1 | cut -d"'" -f2)
    
    # 2. 追溯最底层的 Base 镜像 (原始磁盘)
    # 使用 qemu-img 查找链条末端的那个文件
    BASE_FILE=$(qemu-img info "$TARGET_FILE" --backing-chain | grep "image:" | tail -n 1 | cut -d":" -f2 | xargs)
    
    if [[ "$TARGET_FILE" == "$BASE_FILE" ]]; then
        echo "ℹ️ 提示：当前已是独立磁盘，无父级快照可合并。"
        exit 0
    fi

    # 3. 收集所有待清理的中间物理文件 (从当前往回找，直到 BASE)
    EXPIRED_FILES=()
    TEMP_PATH="$TARGET_FILE"
    while true; do
        # 获取当前文件的父镜像
        P_FILE=$(qemu-img info "$TEMP_PATH" | grep "backing file:" | cut -d":" -f2 | xargs)
        if [[ -z "$P_FILE" ]]; then break; fi
        
        EXPIRED_FILES+=("$TEMP_PATH")
        TEMP_PATH="$P_FILE"
    done

    echo "📊 检测到末端节点，即将执行【全链条合并】："
    echo " 1. 数据流向: $TARGET_SNAP 及其所有祖先 -> 写入 $BASE_FILE"
    echo " 2. 待删除物理文件: ${EXPIRED_FILES[*]}"
    echo " 3. 虚拟机配置: 将重定向至 $BASE_FILE"
    echo "------------------------------------------------"
    read -p "确认执行全链条合并？(y/N): " CONFIRM

    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        echo "🚀 正在执行全链条数据合并 (此操作耗时较长)..."
        # qemu-img commit 会将数据逐级向上（向 Base 方向）提交
        if qemu-img commit -p "$TARGET_FILE"; then
            
            echo "🚀 正在更新虚拟机磁盘配置..."
            virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}_bak.xml
            sed "s|source file='$TARGET_FILE'|source file='$BASE_FILE'|g" /tmp/${VM_NAME}_bak.xml > /tmp/${VM_NAME}_new.xml
            virsh define /tmp/${VM_NAME}_new.xml

            echo "🚀 正在清理物理文件..."
            for f in "${EXPIRED_FILES[@]}"; do
                [ -f "$f" ] && rm -v "$f"
            done

            echo "🚀 正在递归清理所有快照元数据..."
            # 从当前快照开始向上清理所有元数据
            CURR_MD="$TARGET_SNAP"
            while [[ -n "$CURR_MD" ]]; do
                PARENT_MD=$(virsh snapshot-parent "$VM_NAME" "$CURR_MD" 2>/dev/null || echo "")
                echo "清理元数据: $CURR_MD"
                virsh snapshot-delete "$VM_NAME" "$CURR_MD" --metadata
                CURR_MD="$PARENT_MD"
            done

            echo "✅ 全链条合并完成！虚拟机现在运行在原始磁盘 $BASE_FILE 上。"
        else
            echo "❌ 错误：数据合并过程中发生异常。"
            exit 1
        fi
    fi
    exit 0

elif [ ${#CHILDREN[@]} -gt 1 ]; then
    echo "❓ 发现该快照有多个直接分支: ${CHILDREN[*]}"
    while true; do
        read -p "请手动输入要保留并重定向的分支快照名称: " KEEP_SNAP
        valid=false
        for c in "${CHILDREN[@]}"; do
            [[ "$c" == "$KEEP_SNAP" ]] && valid=true && break
        done
        if $valid; then break; else echo "❌ 错误：不在分支列表中。"; fi
    done
else
    KEEP_SNAP=${CHILDREN[0]}
    echo "🔍 自动识别后续快照为: $KEEP_SNAP"
fi

# --- 5. 解析文件路径 ---
TARGET_FILE=$(virsh snapshot-dumpxml "$VM_NAME" "$TARGET_SNAP" | grep "<source file=" | head -n 1 | cut -d"'" -f2)
KEEP_FILE=$(virsh snapshot-dumpxml "$VM_NAME" "$KEEP_SNAP" | grep "<source file=" | head -n 1 | cut -d"'" -f2)
BASE_FILE=$(qemu-img info "$TARGET_FILE" --backing-chain | grep "image:" | tail -n 1 | cut -d":" -f2 | xargs)

if [[ ! -f "$TARGET_FILE" || ! -f "$KEEP_FILE" ]]; then
    echo "❌ 错误：物理磁盘文件不存在，无法继续。"
    exit 1
fi

# 收集所有待清理的物理文件（从 TARGET 往回找直到 BASE）
EXPIRED_FILES=()
TEMP_PATH="$TARGET_FILE"
while [[ "$TEMP_PATH" != "$BASE_FILE" && -n "$TEMP_PATH" ]]; do
    EXPIRED_FILES+=("$TEMP_PATH")
    TEMP_PATH=$(qemu-img info "$TEMP_PATH" | grep "backing file:" | cut -d":" -f2 | xargs)
done

# --- 6. 确认并执行 ---
echo ""
echo "📝 即将执行的操作："
echo " 1. 合并数据: $TARGET_SNAP 及其祖先 -> $BASE_FILE"
echo " 2. 重定向: $KEEP_SNAP -> 现在直接指向 $BASE_FILE"
echo " 3. 物理删除: ${EXPIRED_FILES[*]}"
echo "------------------------------------------------"
read -p "确认无误并执行合并？(y/N): " CONFIRM

if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
    echo "🚀 正在合并磁盘数据 (qemu-img commit)..."
    if qemu-img commit -p "$TARGET_FILE"; then
        echo "🚀 正在重连快照链 (qemu-img rebase)..."
        qemu-img rebase -u -b "$BASE_FILE" -F qcow2 "$KEEP_FILE"

        echo "🚀 正在清理物理文件..."
        for file in "${EXPIRED_FILES[@]}"; do
            [ -f "$file" ] && rm -v "$file"
        done

        echo "🚀 正在递归清理 Libvirt 快照元数据..."
        # 从 TARGET_SNAP 开始向上递归寻找所有父节点
        CURR_MD="$TARGET_SNAP"
        while [[ -n "$CURR_MD" ]]; do
            PARENT_MD=$(virsh snapshot-parent "$VM_NAME" "$CURR_MD" 2>/dev/null || echo "")
            echo "清理元数据: $CURR_MD"
            virsh snapshot-delete "$VM_NAME" "$CURR_MD" --metadata
            CURR_MD="$PARENT_MD"
        done

        echo "✅ 操作成功完成！"
    else
        echo "❌ 错误：数据合并失败。"
        exit 1
    fi
else
    echo "☕ 操作已取消。"
fi
