#!/bin/bash
# Script: plr_resume.sh
# Uso: ./plr_resume.sh "<fichero.gcode>" <X> <Y> <Z>

# --- Cargar configuración ---
# Busca el fichero .conf en el mismo directorio que este script
CONFIG_FILE="$(dirname "$0")/plr_resume.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ADVERTENCIA: No se encontró '$CONFIG_FILE'. Usando valores internos por defecto."
fi

# --- Variables ---
# Usa variables del .conf o valores por defecto si el .conf no existe o no las define
DIR="${PRINTER_DATA_DIR:-/home/pi/printer_data/gcodes}"
DEFAULT_TEMP_CAMA=${DEFAULT_TEMP_CAMA:-60}
DEFAULT_TEMP_EXTRUSOR=${DEFAULT_TEMP_EXTRUSOR:-200}
DEFAULT_FAN_CMD="${DEFAULT_FAN_CMD:-M107}"
MOONRAKER_URL="${MOONRAKER_URL:-http://127.0.0.1:7125}"

# --- Argumentos ---
FICHERO="$1"
POS_X="$2"
POS_Y="$3"
POS_Z="$4"
FULLPATH="$DIR/$FICHERO"

if [ -z "$FULLPATH" ] || [ -z "$POS_X" ] || [ -z "$POS_Y" ] || [ -z "$POS_Z" ]; then
    echo "Uso: $0 <fichero.gcode> <X> <Y> <Z>"
    exit 1
fi

if [ ! -f "$FULLPATH" ]; then
    echo "ERROR: fichero no encontrado: $FULLPATH"
    exit 1
fi

# --- Buscar la línea _PLR_Z Z=$POS_Z ---
LINEA_Z=$(grep -n "_PLR_Z\s*Z\s*=\s*${POS_Z}" "$FULLPATH" | head -1 | cut -d: -f1)
if [ -z "$LINEA_Z" ]; then
    echo "No se encontró la marca _PLR_Z Z=$POS_Z"
    exit 1
fi

# --- Buscar parámetros opcionales antes de _PLR_Z ---
LINEA_BEFORE=$(head -n $((LINEA_Z-1)) "$FULLPATH")
TOTAL_LAYER=$(echo "$LINEA_BEFORE" | grep "SET_PRINT_STATS_INFO TOTAL_LAYER" | tail -1)
CURRENT_LAYER=$(echo "$LINEA_BEFORE" | grep "SET_PRINT_STATS_INFO CURRENT_LAYER" | tail -1)
ACTIVE_SPOOL=$(echo "$LINEA_BEFORE" | grep "SET_ACTIVE_SPOOL" | tail -1)
PRESSURE_ADVANCE=$(echo "$LINEA_BEFORE" | grep "SET_PRESSURE_ADVANCE" | tail -1)
EXTRUDER_TOOL=$(echo "$LINEA_BEFORE" | grep "^T[0-9]+" | tail -1)

# --- Buscar la mejor coincidencia de X Y después de LINEA_Z ---
LINEA_XY=$(tail -n +"$LINEA_Z" "$FULLPATH" | grep -n -E "G1 .*X${POS_X} .*Y${POS_Y}" | head -1 | cut -d: -f1)
if [ -z "$LINEA_XY" ]; then
    LINEA="$LINEA_Z"
else
    LINEA=$((LINEA_Z + LINEA_XY - 1))
fi

echo "Línea de corte: $LINEA"

# --- Recuperar temperaturas y ventilador ---
TEMP_CAMA=$(head -n $LINEA "$FULLPATH" | grep -E "M190|M140" | tail -1 | grep -oP "S[0-9]+" | tr -d 'S')
TEMP_EXTRUSOR=$(head -n $LINEA "$FULLPATH" | grep -E "M109|M104" | tail -1 | grep -oP "S[0-9]+" | tr -d 'S')
[ -z "$TEMP_CAMA" ] && TEMP_CAMA=$DEFAULT_TEMP_CAMA
[ -z "$TEMP_EXTRUSOR" ] && TEMP_EXTRUSOR=$DEFAULT_TEMP_EXTRUSOR
FAN_CMD=$(head -n $LINEA "$FULLPATH" | grep -E "M106|M107" | tail -1)
[ -z "$FAN_CMD" ] && FAN_CMD="$DEFAULT_FAN_CMD"

# --- Crear recovery file con "_recovery" al final del nombre ---
DIRNAME=$(dirname "$FULLPATH")
BASENAME=$(basename "$FULLPATH")
EXTENSION="${BASENAME##*.}"
NAME="${BASENAME%.*}"
NUEVO="${DIRNAME}/${NAME}_recovery.${EXTENSION}"
RECOVERY_BASENAME=$(basename "$NUEVO")

{
    echo "; === POWER LOSS RECOVERY FILE ==="
    [ -n "$TOTAL_LAYER" ] && echo "$TOTAL_LAYER"
    [ -n "$CURRENT_LAYER" ] && echo "$CURRENT_LAYER"
    [ -n "$ACTIVE_SPOOL" ] && echo "$ACTIVE_SPOOL"
    [ -n "$PRESSURE_ADVANCE" ] && echo "$PRESSURE_ADVANCE"
    [ -n "$EXTRUDER_TOOL" ] && echo "$EXTRUDER_TOOL"

    echo "M140 S$TEMP_CAMA"
    echo "M104 S$TEMP_EXTRUSOR"
    echo "$FAN_CMD"
    
    echo "M190 S$TEMP_CAMA"
    echo "M109 S$TEMP_EXTRUSOR"

    echo "CLEAN_NOZZLE"
        
    echo "G90"
    echo "G1 X$POS_X Y$POS_Y F6000"
    echo "G1 Z$POS_Z F6000"
    
    echo "_PLR_PRINT_START"
    
    echo "; --- Resumen desde línea original $LINEA ---"
    tail -n +$LINEA "$FULLPATH"
} > "$NUEVO"

# --- Enviar recovery a Moonraker ---
if [ -f "$NUEVO" ]; then
    nohup curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"script\": \"_PLR_AUTO_PRINT_RECOVERY FILE=\\\"${RECOVERY_BASENAME}\\\"\"}" \
      "$MOONRAKER_URL/printer/gcode/script" >/dev/null 2>&1 &
    echo "Moonraker start-request enviado (async) para: $RECOVERY_BASENAME"
else
    echo "ERROR: recovery file no encontrado: $NUEVO"
fi