#!/usr/bin/env bash
# air-chart 边界测试用例批量验证 (30 组)
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
t() { # t <描述> <期望退出码> <命令...>
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [[ "$rc" == "$want" ]]; then pass=$((pass+1)); printf 'PASS [%s] rc=%s\n' "$desc" "$rc"
  else fail=$((fail+1)); printf 'FAIL [%s] rc=%s want=%s\n' "$desc" "$rc" "$want"; fi
}
D=--demo
t "小写城市名"            0 ./scripts/air_chart.sh --city beijing $D -o /tmp/t01.svg
t "大小写混合"             0 ./scripts/air_chart.sh --city tOKyo $D -o /tmp/t02.svg
t "带空格城市名"          0 ./scripts/air_chart.sh --city "New Delhi" $D -o /tmp/t03.svg
t "包含匹配 delhi"        0 ./scripts/air_chart.sh --city delhi $D -o /tmp/t04.svg
t "包含匹配 york"         0 ./scripts/air_chart.sh --city york $D -o /tmp/t05.svg
t "坐标直传"              0 ./scripts/air_chart.sh --city "39.9,116.4" $D -o /tmp/t06.svg
t "负纬度坐标"            0 ./scripts/air_chart.sh --city "-33.87,151.21" $D -o /tmp/t07.svg
t "生僻城市(内置库有)"    0 ./scripts/air_chart.sh --city Ulaanbaatar $D -o /tmp/t08.svg
t "不存在城市"            2 ./scripts/air_chart.sh --city Atlantis $D -o /tmp/t09.svg
t "空城市串"              2 ./scripts/air_chart.sh --city "" $D -o /tmp/t10.svg
t "24h 小时级"            0 ./scripts/air_chart.sh --city Beijing $D -t 24h -o /tmp/t11.svg
t "48h 小时级"            0 ./scripts/air_chart.sh --city Beijing $D -t 48h -o /tmp/t12.svg
t "14d 日级"              0 ./scripts/air_chart.sh --city Beijing $D -t 14d -o /tmp/t13.svg
t "30d 日级"              0 ./scripts/air_chart.sh --city Beijing $D -t 30d -o /tmp/t14.svg
t "非法跨度"              1 ./scripts/air_chart.sh --city Beijing $D -t 99d -o /tmp/t15.svg
t "全指标遍历-pm10"       0 ./scripts/air_chart.sh --city Beijing $D -p pm10 -o /tmp/t16.svg
t "全指标遍历-o3"         0 ./scripts/air_chart.sh --city Beijing $D -p o3 -o /tmp/t17.svg
t "全指标遍历-no2"        0 ./scripts/air_chart.sh --city Beijing $D -p no2 -o /tmp/t18.svg
t "全指标遍历-so2"        0 ./scripts/air_chart.sh --city Beijing $D -p so2 -o /tmp/t19.svg
t "全指标遍历-co"         0 ./scripts/air_chart.sh --city Beijing $D -p co -o /tmp/t20.svg
t "非法指标"              1 ./scripts/air_chart.sh --city Beijing $D -p xyz -o /tmp/t21.svg
t "4 城对比(上限)"        0 ./scripts/air_chart.sh -c Beijing -c Tokyo -c Seoul -c London $D -o /tmp/t22.svg
t "5 城(超上限)"          1 ./scripts/air_chart.sh -c Beijing -c Tokyo -c Seoul -c London -c Paris $D -o /tmp/t23.svg
t "多城+多指标(冲突)"     1 ./scripts/air_chart.sh -c Beijing -c Tokyo -p pm25 -p pm10 $D -o /tmp/t24.svg
t "同城 2 指标"           0 ./scripts/air_chart.sh -c Beijing -p pm25 -p pm10 $D -o /tmp/t25.svg
t "同城 4 指标"           0 ./scripts/air_chart.sh -c Beijing -p pm25 -p pm10 -p o3 -p no2 $D -o /tmp/t26.svg
t "快照模式"              0 ./scripts/air_chart.sh -c Delhi -p pm10 --snapshot $D -o /tmp/t27.svg
t "深色主题"              0 ./scripts/air_chart.sh -c Beijing $D --theme dark -o /tmp/t28.svg
t "无 Key 真实调用"       3 env -u OPENAQ_API_KEY ./scripts/air_chart.sh -c Beijing -o /tmp/t29.svg
t "未指定城市"            1 ./scripts/air_chart.sh $D -o /tmp/t30.svg
echo "== pass=$pass fail=$fail =="
