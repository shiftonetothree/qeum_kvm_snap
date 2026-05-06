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

# --- 3. 展示快照列表并选择目标 ---
echo ""
echo "📊 该虚拟机的快照链结构："
virsh snapshot-list "$VM_NAME" --tree
echo "------------------------------------------------"
