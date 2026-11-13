#!/usr/bin/env bash
# air_chart.sh — air-chart 主入口
# 自然语言查询 -> OpenAQ 站点优选 -> 数据清洗 -> SVG 图表
#
# 用法:
#   air_chart.sh --city Beijing --param pm25 --period 7d
#   air_chart.sh --city Tokyo --city Seoul --param pm25 --period 7d     # 多城对比
#   air_chart.sh --city Beijing --param pm25 --param pm10 --period 48h  # 单城多指标
#   air_chart.sh --city Delhi --param pm10 --snapshot                   # 同城多站点快照
#   air_chart.sh --city Beijing --param pm25 --period 7d --demo         # 演示数据(免 API Key)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./openaq_client.sh
source "$SCRIPT_DIR/openaq_client.sh"

# ---------- 参数默认值 ----------
CITIES=(); PARAMS=("pm25"); PERIOD="7d"; SNAPSHOT=0; THEME="light"; OUT=""; DEMO=0
declare -A WHO_BASELINE=( [pm25]=15 [pm10]=45 [o3]=100 [no2]=25 [so2]=40 [co]=4 )
declare -A PARAM_LABEL=( [pm25]="PM2.5" [pm10]="PM10" [o3]="O3" [no2]="NO2" [so2]="SO2" [co]="CO" )
declare -A PARAM_UNITS=( [pm25]="µg/m³" [pm10]="µg/m³" [o3]="µg/m³" [no2]="µg/m³" [so2]="µg/m³" [co]="mg/m³" )
VALID_PARAMS="pm25 pm10 o3 no2 so2 co"

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}"; }

while (( $# )); do
  case "$1" in
    -c|--city) CITIES+=("$2"); shift 2 ;;
    -p|--param) PARAMS+=("$2"); shift 2 ;;
    -t|--period) PERIOD="$2"; shift 2 ;;
    --snapshot) SNAPSHOT=1; shift ;;
    --theme) THEME="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    --demo) DEMO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[air-chart] ERROR: 未知参数 %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

# 默认参数修正: --param 显式传入时去掉默认值
if (( ${#PARAMS[@]} > 1 )) && [[ "${PARAMS[0]}" == "pm25" ]]; then PARAMS=("${PARAMS[@]:1}"); fi
[[ ${#CITIES[@]} -eq 0 ]] && { printf '[air-chart] ERROR: 请至少通过 --city 指定一个城市。\n' >&2; exit 1; }
[[ ${#CITIES[@]} -gt 4 ]] && { printf '[air-chart] ERROR: 多城对比最多支持 4 个城市。\n' >&2; exit 1; }
for p in "${PARAMS[@]}"; do
  [[ " $VALID_PARAMS " == *" $p "* ]] || { printf '[air-chart] ERROR: 不支持的指标 "%s" (可选: %s)。\n' "$p" "$VALID_PARAMS" >&2; exit 1; }
done
if (( ${#CITIES[@]} > 1 && ${#PARAMS[@]} > 1 )); then
  printf '[air-chart] ERROR: 多城对比模式仅支持单指标, 请只传一个 --param。\n' >&2; exit 1
fi

case "$PERIOD" in
  24h) GRAN="hours"; HOURS=24 ;;
  48h) GRAN="hours"; HOURS=48 ;;
  7d)  GRAN="days";  HOURS=$((7 * 24)) ;;
  14d) GRAN="days";  HOURS=$((14 * 24)) ;;
  30d) GRAN="days";  HOURS=$((30 * 24)) ;;
  *) printf '[air-chart] ERROR: 不支持的时间跨度 "%s" (可选: 24h 48h 7d 14d 30d)。\n' "$PERIOD" >&2; exit 1 ;;
esac

[[ -z "$OUT" ]] && OUT="./air-chart-$(date +%Y%m%d-%H%M%S).svg"

DATE_FROM="$(date -u -d "-$((HOURS + 6)) hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$((HOURS + 6))"H +%Y-%m-%dT%H:%M:%SZ)"
DATE_TO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------- 演示数据生成 ----------
demo_series() { # <city> <param> <gran> <n> -> 生成 label\tvalue 到 stdout
  local city="$1" param="$2" gran="$3" n="$4" seed
  seed=$(( $(printf '%s' "$city$param" | cksum | awk '{print $1}') % 1000 ))
  # 用城市时区生成当地时间标签
  local tz; tz="$(cut -f5 <<<"$GEO_LINE")"
  awk -v seed="$seed" -v n="$n" -v gran="$gran" -v base="$(date +%s)" -v step="$([[ "$gran" == hours ]] && echo 3600 || echo 86400)" -v tz="$tz" '
  BEGIN {
    amp = (gran == "hours") ? 8 : 20
    mid = (gran == "hours") ? 25 : 45
    for (i = n - 1; i >= 0; i--) {
      ts = base - i * step
      cmd = "TZ=" tz " date -d @" ts " \"+%m-%d" ((gran == "hours") ? " %H:00" : "") "\""
      cmd | getline l; close(cmd)
      x = n - 1 - i
      v = mid + amp * sin((x + seed % 24) / (gran == "hours" ? 3.8 : 2.2)) + amp * 0.35 * sin(x / 1.7 + seed)
      if (v < 0.5) v = 0.5
      printf "%s\t%.1f\n", l, v
    }
  }'
}

# ---------- 主流程 ----------
declare -a RENDER_SPECS=(); declare -a CITY_NOTES=()
FIRST_UNITS=""; FIRST_TZ=""

fetch_city_series() { # <city> -> 为每个 param 生成 series 文件, 输出到 RENDER_SPECS
  local city="$1"
  GEO_LINE="$("$SCRIPT_DIR/geo_resolve.sh" "$city")" || exit $?
  local lat lon tz
  lat="$(cut -f3 <<<"$GEO_LINE")"; lon="$(cut -f4 <<<"$GEO_LINE")"; tz="$(cut -f5 <<<"$GEO_LINE")"
  local geo_name; geo_name="$(cut -f1 <<<"$GEO_LINE")"
  [[ -z "${FIRST_GEO_NAME:-}" ]] && FIRST_GEO_NAME="$geo_name"

  local locations
  locations="$(openaq_find_locations "$lat" "$lon" 25000)"
  local active
  active="$(openaq_filter_active "$locations" 24)"
  if [[ "$(jq '(.results // []) | length' <<<"$active")" == "0" ]]; then
    # 24h 无活性站点, 放宽到 72h 再试一次
    active="$(openaq_filter_active "$locations" 72)"
  fi
  if [[ "$(jq '(.results // []) | length' <<<"$active")" == "0" ]]; then
    printf '[air-chart] WARN: %s 附近 25km 内没有活性监测站点 (24-72h 内无数据更新)。\n' "$city" >&2
    return 1
  fi

  for param in "${PARAMS[@]}"; do
    local picked
    picked="$(openaq_pick_sensor "$active" "$param")"
    if [[ -z "$picked" ]]; then
      printf '[air-chart] WARN: %s 的活性站点中暂无 %s 传感器数据, 已跳过。\n' "$city" "${PARAM_LABEL[$param]}" >&2
      continue
    fi
    local sensor_id units stz sname monitor
    sensor_id="$(cut -f1 <<<"$picked")"; units="$(cut -f2 <<<"$picked")"
    stz="$(cut -f3 <<<"$picked")"; sname="$(cut -f4 <<<"$picked")"; monitor="$(cut -f5 <<<"$picked")"
    [[ -z "$units" || "$units" == "null" ]] && units="${PARAM_UNITS[$param]}"
    [[ -z "$FIRST_UNITS" ]] && { FIRST_UNITS="$units"; FIRST_TZ="$stz"; }

    local raw clean
    raw="$(openaq_fetch_series "$sensor_id" "$GRAN" "$DATE_FROM" "$DATE_TO")"
    clean="$WORK/${geo_name}.${param}.tsv"
    awk -v gran="$GRAN" -v stats="$WORK/${geo_name}.${param}.stats" \
        -f "$SCRIPT_DIR/data_transform.awk" <<<"$raw" > "$clean"
    if [[ ! -s "$clean" ]]; then
      printf '[air-chart] WARN: %s %s 在时间范围内无有效数据点。\n' "$city" "${PARAM_LABEL[$param]}" >&2
      continue
    fi
    RENDER_SPECS+=("${geo_name} ${PARAM_LABEL[$param]}:${clean}")
    local st_min st_max st_avg st_cnt
    st_cnt="$(awk -F'\t' '$1=="count"{print $2}' "$WORK/${geo_name}.${param}.stats")"
    st_min="$(awk -F'\t' '$1=="min"{print $2}' "$WORK/${geo_name}.${param}.stats")"
    st_max="$(awk -F'\t' '$1=="max"{print $2}' "$WORK/${geo_name}.${param}.stats")"
    st_avg="$(awk -F'\t' '$1=="avg"{print $2}' "$WORK/${geo_name}.${param}.stats")"
    CITY_NOTES+=("  - ${geo_name} · ${PARAM_LABEL[$param]} · 站点: ${sname}$( [[ "$monitor" == "true" ]] && echo ' (参考级)') · n=${st_cnt} min=${st_min} max=${st_max} avg=$(printf '%.1f' "$st_avg") ${units}")
  done
}

fetch_city_snapshot() { # <city> <param> -> 渲染柱状图所需 items
  local city="$1" param="$2"
  GEO_LINE="$("$SCRIPT_DIR/geo_resolve.sh" "$city")" || exit $?
  local lat lon tz geo_name
  lat="$(cut -f3 <<<"$GEO_LINE")"; lon="$(cut -f4 <<<"$GEO_LINE")"; tz="$(cut -f5 <<<"$GEO_LINE")"
  geo_name="$(cut -f1 <<<"$GEO_LINE")"

  local locations active
  locations="$(openaq_find_locations "$lat" "$lon" 25000)"
  active="$(openaq_filter_active "$locations" 24)"
  [[ "$(jq '(.results // []) | length' <<<"$active")" == "0" ]] && active="$(openaq_filter_active "$locations" 72)"
  local sensors
  sensors="$(openaq_pick_all_sensors "$active" "$param" | head -6)"
  if [[ -z "$sensors" ]]; then
    printf '[air-chart] WARN: %s 附近没有可用于快照的活性 %s 站点。\n' "$city" "${PARAM_LABEL[$param]}" >&2
    return 1
  fi
  local items=() units=""
  while IFS=$'\t' read -r sensor_id u s_tz s_name monitor; do
    [[ -z "$sensor_id" ]] && continue
    local latest v utc_ts
    latest="$(openaq_fetch_latest "$sensor_id")"
    [[ -z "$latest" ]] && continue
    v="$(cut -f3 <<<"$latest")"; utc_ts="$(cut -f1 <<<"$latest")"
    [[ -z "$units" ]] && units="$u"
    items+=("${s_name}:${v}")
    CITY_NOTES+=("  - ${s_name}$( [[ "$monitor" == "true" ]] && echo ' (参考级)') · 最新: ${v} ${u} @ ${utc_ts} UTC")
  done <<<"$sensors"
  [[ ${#items[@]} -eq 0 ]] && { printf '[air-chart] WARN: 站点最新数据均不可用。\n' >&2; return 1; }
  [[ -z "$units" || "$units" == "null" ]] && units="${PARAM_UNITS[$param]}"
  FIRST_UNITS="$units"
  local who="${WHO_BASELINE[$param]}"
  "$SCRIPT_DIR/render_draw.sh" bar \
    --title "$geo_name 各监测点 ${PARAM_LABEL[$param]} 实时快照" \
    --subtitle "数据来源 OpenAQ · $(TZ="$tz" date '+%Y-%m-%d %H:%M %Z') · 25km 半径内活性站点" \
    --ylabel "$units" \
    --items "${items[@]}" \
    ${who:+--who "$who" --who-label "WHO 基准"} \
    --theme "$THEME" --width 960 --height $((120 + 60 * ${#items[@]})) \
    --out "$OUT"
}

# ---------- 执行 ----------
if (( ! DEMO )); then
  openaq_require_key
fi

if (( SNAPSHOT )); then
  if (( DEMO )); then
    # 演示快照
    demo_city="${CITIES[0]}"
    items=("朝阳公园:32.4" "奥体中心:45.1" "万寿西宫:51.8" "通州:58.2" "昌平:26.9" "大兴:63.5")
    FIRST_UNITS="µg/m³"
    CITY_NOTES=("  - 演示数据模式, 未请求真实 API")
    "$SCRIPT_DIR/render_draw.sh" bar \
      --title "$demo_city 各监测点 PM2.5 实时快照 (演示)" \
      --subtitle "数据来源 OpenAQ · 演示模式 · 25km 半径内活性站点" \
      --ylabel "µg/m³" --items "${items[@]}" \
      --who 15 --who-label "WHO 基准" --theme "$THEME" \
      --width 960 --height 480 --out "$OUT"
  else
    fetch_city_snapshot "${CITIES[0]}" "${PARAMS[0]}"
  fi
  printf '\n[air-chart] 快照已生成: %s\n%s\n' "$OUT" "${CITY_NOTES[*]}"
  exit 0
fi

for city in "${CITIES[@]}"; do
  if (( DEMO )); then
    GEO_LINE="$("$SCRIPT_DIR/geo_resolve.sh" "$city")" || exit $?
    geo_name="$(cut -f1 <<<"$GEO_LINE")"
    [[ -z "${FIRST_GEO_NAME:-}" ]] && FIRST_GEO_NAME="$geo_name"
    for param in "${PARAMS[@]}"; do
      clean="$WORK/${geo_name}.${param}.tsv"
      demo_series "$city" "$param" "$GRAN" "$((HOURS / ($( [[ "$GRAN" == hours ]] && echo 1 || echo 24 ))))" > "$clean"
      FIRST_UNITS="${PARAM_UNITS[$param]}"; FIRST_TZ="$(cut -f5 <<<"$GEO_LINE")"
      RENDER_SPECS+=("${geo_name} ${PARAM_LABEL[$param]}:${clean}")
    done
    CITY_NOTES+=("  - ${geo_name}: 演示数据模式 (未请求真实 API)")
  else
    fetch_city_series "$city" || true
  fi
done

if (( ${#RENDER_SPECS[@]} == 0 )); then
  printf '[air-chart] ERROR: 没有任何序列可绘制。请检查城市名/指标/时间范围, 或使用 --demo 预览效果。\n' >&2
  exit 5
fi

param0="${PARAMS[0]}"
who="${WHO_BASELINE[$param0]:-}"
city_count=${#CITIES[@]}
# 仅拼接用户请求的指标名
param_labels=""
for p in "${PARAMS[@]}"; do param_labels+="${param_labels:+ / }${PARAM_LABEL[$p]}"; done
ylabel="${PARAM_LABEL[$param0]} (${FIRST_UNITS})"
if (( city_count > 1 )); then
  title="${PARAM_LABEL[$param0]} 走势对比 · 最近 $PERIOD"
  subtitle="数据来源 OpenAQ · 多城市同指标对比 · 站点当地时间"
else
  gname="${FIRST_GEO_NAME:-${CITIES[0]}}"
  title="$gname $param_labels 趋势 · 最近 $PERIOD"
  if (( ${#PARAMS[@]} > 1 )); then
    subtitle="数据来源 OpenAQ · 单城市多指标对比 · 站点当地时间"
    ylabel="浓度 (${FIRST_UNITS})"
  else
    subtitle="数据来源 OpenAQ · 站点当地时间 ($FIRST_TZ)"
  fi
fi

"$SCRIPT_DIR/render_draw.sh" line \
  --title "$title" --subtitle "$subtitle" \
  --ylabel "$ylabel" \
  --series "${RENDER_SPECS[@]}" \
  ${who:+--who "$who" --who-label "WHO 24h 基准"} \
  --theme "$THEME" --out "$OUT"

printf '\n[air-chart] 图表已生成: %s\n' "$OUT"
if (( ${#CITY_NOTES[@]} )); then
  printf '[air-chart] 数据摘要:\n%s\n' "${CITY_NOTES[*]}"
fi
