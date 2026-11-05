#!/usr/bin/env bash
# Prueba completa del sistema PLR: impresion seca -> corte simulado -> recuperacion.
#
# Seguro: Z=0.8, sin extrusion salvo la purga. NO imprime una pieza real.
# Requiere:
#   - la impresora encendida y Klipper en "ready"
#   - la cama vacia y la zona de purga (X250) despejada
#   - sudo sin contrasena para systemctl (el script para y arranca klipper)
#
# Uso: ./tests/plr_recovery_test.sh
# Sale con codigo 0 si no hay ningun FAIL.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PLR_PY:-$REPO/venv/bin/python3}"
BASE="http://127.0.0.1:7125"
CFG="$HOME/printer_data/config"
GCODES="$HOME/printer_data/gcodes"
LOG="$HOME/printer_data/logs/klippy.log"
TEST="plr_test.gcode"
PASS=0; FAIL=0; STARTED=0

ok()  { printf '  [OK]   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
api() { curl -s --max-time 10 "$BASE$1"; }
post() { curl -s --max-time 60 -X POST "$BASE$1"; }
state() { api "/printer/objects/query?print_stats" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["status"]["print_stats"].get("state",""))' 2>/dev/null; }
kstate() { api "/printer/info" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"].get("state",""))' 2>/dev/null; }
fname() { api "/printer/objects/query?print_stats" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["status"]["print_stats"].get("filename",""))' 2>/dev/null; }
var() { grep -E "^$1 = " "$CFG/variables.cfg" | head -n1 | sed 's/.*= //' | tr -d "'\""; }
wait_for() { # wait_for <funcion> <valor> <segundos>
  local fn=$1 want=$2 t=${3:-60} i=0
  while [ $i -lt "$t" ]; do [ "$($fn)" = "$want" ] && return 0; sleep 1; i=$((i+1)); done
  return 1
}
cleanup() {
  if [ "$STARTED" = "1" ]; then
    case "$(state)" in printing|paused) post "/printer/print/cancel" >/dev/null 2>&1;; esac
  fi
  rm -f "$GCODES/$TEST" "$GCODES/plr_test_recovery_"*.gcode 2>/dev/null
}
trap cleanup EXIT

echo "== 0. Preflight =="
[ -x "$PY" ] || { echo "No encuentro $PY. Ejecuta install.sh primero."; exit 1; }
if [ "$(kstate)" != "ready" ]; then
  echo "Klipper no esta ready. Enciende la impresora y espera."; exit 1
fi
ok "Klipper ready"
if [ "$(state)" = "printing" ] || [ "$(state)" = "paused" ]; then
  echo "Hay una impresion en curso. Cancelala antes de probar."; exit 1
fi
ok "sin impresion en curso"
if [ "$(var plr_activate)" = "True" ]; then
  echo "plr_activate=True de una prueba anterior. Ejecuta _PLR_STOP antes."; exit 1
fi
ok "estado PLR limpio"

echo "== 1. Datos de prueba =="
cat > "$GCODES/$TEST" <<'GCODE'
; PLR dry test - sin extrusion
_PLR_PRINT_START
G28
G90
M104 S200
M109 S200
SET_PRINT_STATS_INFO CURRENT_LAYER=1
;LAYER_CHANGE
G1 Z0.8 F600
G1 X100 Y100 F3000
G1 X130 Y100 F600
G4 P8000
G1 X130 Y130 F600
G4 P8000
G1 X100 Y130 F600
G4 P8000
G1 X100 Y100 F600
G4 P30000
_PLR_STOP
GCODE
ok "G-code de prueba creado"

echo "== 2. Iniciar impresion =="
sleep 2
post "/printer/print/start?filename=$TEST" >/dev/null
STARTED=1
if wait_for state printing 60; then ok "estado printing"; else bad "no arranca la impresion"; exit 1; fi

echo "== 3. Esperar un guardado valido del ticker =="
i=0; SAVED=""
while [ $i -lt 180 ]; do
  PD="$(var plr_data | tr -d '() ')"
  B="${PD%%,*}"; R="${PD#*,}"; ZV="${R#*,}"
  if [ "$(var plr_activate)" = "True" ] && [ -n "${B:-}" ] && [ "$B" -gt 100 ] 2>/dev/null; then
    if awk -v z="${ZV:-999}" 'BEGIN{exit !(z >= 0 && z <= 50)}'; then SAVED="$PD"; break; fi
  fi
  sleep 1; i=$((i+1))
done
if [ -n "$SAVED" ]; then ok "plr_data valido: $SAVED"; else bad "el ticker no guardo una posicion valida"; exit 1; fi

echo "== 4. Corte simulado =="
sudo systemctl stop klipper
sleep 5
if systemctl is-active --quiet klipper; then bad "klipper sigue activo"; else ok "klipper detenido"; fi
if [ "$(var plr_activate)" = "True" ]; then ok "plr_activate sigue True"; else bad "plr_activate se perdio"; fi
PREV="$(var plr_data)"
ok "posicion conservada: $PREV"

echo "== 5. Rearranque =="
sudo systemctl start klipper
if wait_for kstate ready 120; then ok "klipper ready"; else bad "klipper no arranca"; exit 1; fi
sleep 3

echo "== 6. Recuperar =="
post "/printer/gcode/script?script=_PLR_RECOVERY" >/dev/null
i=0; RECFILE=""
while [ $i -lt 180 ]; do
  RECFILE=$(fname)
  case "$RECFILE" in plr_test_recovery_*) break;; esac
  sleep 1; i=$((i+1))
done
if [ -n "$RECFILE" ] && [ "${RECFILE#plr_test_recovery_}" != "$RECFILE" ]; then
  ok "archivo de recuperacion: $RECFILE"
  ls -lt "$GCODES"/plr_test_recovery_*.gcode 2>/dev/null | head -n1
else
  bad "no se genero/inicio el archivo de recuperacion"; exit 1
fi
grep -a "Recuperando:" "$LOG" | tail -n1

echo "== 7. Verificar ticker tras recuperar =="
i=0; POST=""
while [ $i -lt 240 ]; do
  POST="$(var plr_data)"
  if [ "$POST" != "$PREV" ] && [ "$POST" != "0,0,0" ]; then break; fi
  sleep 2; i=$((i+2))
done
if [ "$POST" != "$PREV" ] && [ "$POST" != "0,0,0" ]; then
  ok "el ticker sigue guardando: $POST"
else
  bad "el ticker no se rearmo tras la recuperacion (P2-27): $POST"
fi

echo "== 8. Cancelar y limpiar =="
post "/printer/print/cancel" >/dev/null
if wait_for state cancelled 30 || wait_for state standby 5; then
  ok "impresion cancelada"
else
  bad "no vuelve a cancelled/standby"
fi
sleep 2
if [ "$(var plr_activate)" = "False" ]; then ok "plr_activate limpiado"; else bad "plr_activate sigue True"; fi

echo
echo "Resultado: ${PASS} OK, ${FAIL} FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
