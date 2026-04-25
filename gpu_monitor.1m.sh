#!/bin/bash
###
 # @Description: 
 # @Author: Feiyang Wang
 # @Date: 2026-04-24 23:09:59
 # @LastEditTime: 2026-04-25 01:28:19
 # @LastEditors: Feiyang Wang
 # @Version: V1.0.0
### 

# ================= 配置区域 =================
# 默认 SSH 私钥。如果某台服务器没有单独指定私钥，会使用这个路径。
ID_FILE="/Users/YOUR_USERNAME/.ssh/id_ed25519"

# 多服务器配置格式：
#   "显示名称|SSH 用户和地址|SSH 私钥路径"
#
# 第 3 段私钥路径可以留空，留空时使用上面的 ID_FILE。
# 示例：
#   "A100-01|user@192.0.2.10|/Users/YOUR_USERNAME/.ssh/id_ed25519"
#   "RTX4090-02|user@192.0.2.11|"
SERVERS=(
  "GPU-01|user@192.0.2.10|$ID_FILE"
  "GPU-02|user@192.0.2.11|$ID_FILE"
)
# ===========================================

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes)
FONT="Menlo"
MUTED_COLOR="#6E6E73"
BUSY_COLOR="#D70015"
REMOTE_QUERY='
nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits | awk -F", " '"'"'{
  printf "GPU|%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, $6
}'"'"'
nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits 2>/dev/null | while IFS=, read -r uuid pid used_mem; do
  uuid=$(printf "%s" "$uuid" | awk '"'"'{$1=$1; print}'"'"')
  pid=$(printf "%s" "$pid" | awk '"'"'{$1=$1; print}'"'"')
  used_mem=$(printf "%s" "$used_mem" | awk '"'"'{$1=$1; print}'"'"')
  [ -z "$uuid" ] && continue
  [ "$uuid" = "No running processes found" ] && continue
  user=$(ps -o user= -p "$pid" 2>/dev/null | awk '"'"'{print $1; exit}'"'"')
  [ -z "$user" ] && user="unknown"
  printf "APP|%s|%s|%s|%s\n" "$uuid" "$user" "$pid" "$used_mem"
done
'

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

short_gpu_name() {
  local name="$1"
  name="${name#NVIDIA }"
  name="${name%%-*}"
  printf '%s' "$(trim "$name")"
}

swiftbar_escape() {
  printf '%s' "$1" | sed 's/|/¦/g'
}

format_gb() {
  awk -v mb="$1" 'BEGIN { printf "%.1fG", mb / 1024 }'
}

gpu_users_for_uuid() {
  local uuid="$1"
  local raw_data="$2"

  printf '%s\n' "$raw_data" | awk -F'|' -v uuid="$uuid" '
    $1 == "APP" && $2 == uuid {
      user = ($3 == "" ? "unknown" : $3)
      if (!seen[user]++) {
        users = users ? users "," user : user
      }
    }
    END {
      print users ? users : "-"
    }
  '
}

is_integer() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

print_terminal_action() {
  local label="$1"
  local host="$2"
  local key_file="$3"

  if [ -n "$key_file" ]; then
    printf "Open Terminal: %s | shell=/usr/bin/ssh param1=-i param2=%s param3=%s terminal=true refresh=true font=%s size=13\n" \
      "$(swiftbar_escape "$label")" "$key_file" "$host" "$FONT"
  else
    printf "Open Terminal: %s | shell=/usr/bin/ssh param1=%s terminal=true refresh=true font=%s size=13\n" \
      "$(swiftbar_escape "$label")" "$host" "$FONT"
  fi
}

total_free=0
total_gpus=0
online_servers=0
offline_servers=0
server_count=0
menu_content=""

for server in "${SERVERS[@]}"; do
  IFS='|' read -r label host key_file <<< "$server"
  label="$(trim "$label")"
  host="$(trim "$host")"
  key_file="$(trim "$key_file")"

  [ -z "$host" ] && continue
  [ -z "$label" ] && label="$host"
  [ -z "$key_file" ] && key_file="$ID_FILE"

  server_count=$((server_count + 1))

  if [ -n "$key_file" ]; then
    raw_data=$(/usr/bin/ssh -i "$key_file" "${SSH_OPTS[@]}" "$host" "$REMOTE_QUERY" 2>&1)
  else
    raw_data=$(/usr/bin/ssh "${SSH_OPTS[@]}" "$host" "$REMOTE_QUERY" 2>&1)
  fi
  ssh_status=$?

  if [ $ssh_status -ne 0 ] || [ -z "$raw_data" ]; then
    offline_servers=$((offline_servers + 1))
    error_preview="$(printf '%s' "$raw_data" | tr '\n' ' ' | cut -c 1-120)"
    menu_content="${menu_content}● $(swiftbar_escape "$label")  Offline | color=${BUSY_COLOR} font=${FONT} size=13 refresh=true
  $(swiftbar_escape "$host") | color=${MUTED_COLOR} font=${FONT} size=11 refresh=true
  Error: $(swiftbar_escape "$error_preview") | color=${BUSY_COLOR} font=${FONT} size=11 refresh=true
$(print_terminal_action "$label" "$host" "$key_file")
---
"
    continue
  fi

  online_servers=$((online_servers + 1))
  server_free=0
  server_total=0
  server_lines=""

  server_lines="    GPU  NAME             VRAM        UTIL  USER | color=${MUTED_COLOR} font=${FONT} size=11 refresh=true
"

  while IFS='|' read -r row_type idx uuid name util mem_used mem_total _; do
    [ "$row_type" = "GPU" ] || continue

    idx="$(trim "$idx")"
    uuid="$(trim "$uuid")"
    name="$(short_gpu_name "$(trim "$name")")"
    util="$(trim "$util")"
    mem_used="$(trim "$mem_used")"
    mem_total="$(trim "$mem_total")"
    users="$(gpu_users_for_uuid "$uuid" "$raw_data")"

    [ -z "$idx" ] && continue
    is_integer "$util" || util=0
    is_integer "$mem_used" || mem_used=0
    is_integer "$mem_total" || mem_total=0

    server_total=$((server_total + 1))
    total_gpus=$((total_gpus + 1))

    mem_free=$((mem_total - mem_used))
    [ "$mem_free" -lt 0 ] && mem_free=0

    if [ "$util" -lt 5 ] && [ "$mem_free" -gt 4000 ]; then
      icon="🟢"
      line_attrs="font=${FONT} size=12 refresh=true"
      server_free=$((server_free + 1))
      total_free=$((total_free + 1))
    else
      icon="🔴"
      line_attrs="font=${FONT} size=12 refresh=true"
    fi

    vram="$(format_gb "$mem_used")/$(format_gb "$mem_total")"
    server_lines="${server_lines}$(printf "  %s %-3s %-16.16s %-11s %3s%%  %-18.18s" "$icon" "[$idx]" "$name" "$vram" "$util" "$users") | ${line_attrs}
"
  done <<< "$raw_data"

  if [ "$server_free" -eq 0 ]; then
    header_dot="🔴"
    header_attrs="refresh=true font=${FONT} size=13"
  else
    header_dot="🟢"
    header_attrs="refresh=true font=${FONT} size=13"
  fi

  menu_content="${menu_content}${header_dot} $(swiftbar_escape "$label")  ${server_free}/${server_total} Free | ${header_attrs}
  $(swiftbar_escape "$host") | color=${MUTED_COLOR} font=${FONT} size=11 refresh=true
${server_lines}$(print_terminal_action "$label" "$host" "$key_file")
---
"
done

if [ "$server_count" -eq 0 ]; then
  echo "GPU: No Servers | color=${BUSY_COLOR}"
  echo "---"
  echo "Please configure SERVERS in gpu_monitor.1m.sh | color=${BUSY_COLOR} font=${FONT} size=12 refresh=true"
  exit 0
fi

top_color=""
if [ "$total_gpus" -eq 0 ] || [ "$total_free" -eq 0 ] || [ "$offline_servers" -gt 0 ]; then
  top_color=" | color=${BUSY_COLOR}"
fi

printf "GPU: %d/%d Free @ %d/%d Servers%s\n" "$total_free" "$total_gpus" "$online_servers" "$server_count" "$top_color"
echo "---"
printf "%s" "$menu_content"
echo "Refresh All | refresh=true font=${FONT} size=13"
