#!/bin/bash

# 1. 列出所有虚拟机，方便用户查看
echo "------------------------------------------------"
echo "当前系统中的虚拟机列表："
virsh list --all
echo "------------------------------------------------"

# 2. 交互式获取虚拟机名称
read -p "请输入要创建快照的虚拟机名称: " VM_NAME

# 3. 检查输入是否为空及虚拟机是否存在
if [ -z "$VM_NAME" ]; then
    echo "错误：虚拟机名称不能为空。"
    exit 1
fi

if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "错误：找不到名为 '$VM_NAME' 的虚拟机，请检查名称是否输入正确。"
    exit 1
fi

# 4. 生成快照名称（带时间戳）
SNAPSHOT_NAME="snap_$(date +%Y%m%d_%H%M%S)"

echo "正在为虚拟机 [$VM_NAME] 创建外部磁盘快照..."
echo "快照名称: $SNAPSHOT_NAME"

# 5. 执行创建命令
# 使用 --no-metadata 参数可以简化管理（如果只是为了临时备份磁盘）
# 这里保留 metadata 以便通过 virsh snapshot-list 追踪
virsh snapshot-create-as --domain "$VM_NAME" \
    --name "$SNAPSHOT_NAME" \
    --disk-only \
    --atomic

# 6. 结果反馈
if [ $? -eq 0 ]; then
    echo "------------------------------------------------"
    echo "✅ 成功：外部快照已创建。"
    echo "注意：当前虚拟机正在往新的增量磁盘文件中写入数据。"
    echo "你可以运行 'virsh domblklist $VM_NAME' 查看当前正在使用的磁盘文件。"
else
    echo "❌ 失败：创建快照时遇到问题。"
    exit 1
fi
