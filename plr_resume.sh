#!/bin/bash

# --- Configuración ---
PRINTER_DATA_DIR="/home/pi/printer_data/gcodes"
MOONRAKER_URL="http://127.0.0.1:7125"

# --- Argumentos ---
RAW_FICHERO="$1"
RAW_BYTE_POS="$2"
RAW_POS_Z="$3"

# --- LIMPIEZA DE VARIABLES (CRÍTICO) ---
# 1. Quitar comillas y asegurar ruta absoluta
FICHERO=$(echo "$RAW_FICHERO" | tr -d '"')
FULLPATH="$PRINTER_DATA_DIR/$FICHERO"

# 2. Convertir posiciones a números ENTEROS (quitando decimales)
# Ej: 1234.56 -> 1234
BYTE_POS=$(echo "$RAW_BYTE_POS" | cut -d'.' -f1 | tr -d ' ')
POS_Z_INT=$(echo "$RAW_POS_Z" | cut -d'.' -f1 | tr -d ' ')
# Mantenemos POS_Z con decimales para el movimiento G1, pero sin espacios
POS_Z=$(echo "$RAW_POS_Z" | tr -d ' ')

# Validaciones de depuración en el log
echo "DEBUG: Fichero=$FULLPATH"
echo "DEBUG: Byte=$BYTE_POS"
echo "DEBUG: Z=$POS_Z"

if [ ! -f "$FULLPATH" ]; then
    echo "ERROR: No se encuentra el archivo: $FULLPATH"
    exit 1
fi

# 3. Ajuste al inicio de línea
AJUSTE_BYTE=$(head -c "$BYTE_POS" "$FULLPATH" | grep -aob "$" | tail -1 | cut -d: -f1)
if [ -z "$AJUSTE_BYTE" ]; then
    FINAL_BYTE=$BYTE_POS
else
    FINAL_BYTE=$((AJUSTE_BYTE + 1))
fi

# 4. Mirar el futuro (Primer movimiento)
NEXT_MOVE=$(tail -c +"$FINAL_BYTE" "$FULLPATH" | grep -m 1 -E "^G0|^G1" | grep -E "X|Y")
TARGET_X=$(echo "$NEXT_MOVE" | grep -oP "X[0-9.-]+")
TARGET_Y=$(echo "$NEXT_MOVE" | grep -oP "Y[0-9.-]+")

# 5. Procesar encabezado
HEADER_CHUNK=$(head -c "$FINAL_BYTE" "$FULLPATH")

# Extraer parámetros (Temperaturas, Fans, Metadatos)
TEMP_CAMA=$(echo "$HEADER_CHUNK" | grep -E "M190|M140" | tail -1 | grep -oP "S[0-9.]+" | tr -d 'S')
TEMP_EXTRUSOR=$(echo "$HEADER_CHUNK" | grep -E "M109|M104" | tail -1 | grep -oP "S[0-9.]+" | tr -d 'S')
FAN_CMD=$(echo "$HEADER_CHUNK" | grep -E "M106|M107" | tail -1 | cut -d';' -f1)

[ -z "$TEMP_CAMA" ] && TEMP_CAMA=60
[ -z "$TEMP_EXTRUSOR" ] && TEMP_EXTRUSOR=200
[ -z "$FAN_CMD" ] && FAN_CMD="M107"

# --- Generar Archivo de Recuperación ---
NUEVO="${PRINTER_DATA_DIR}/RECOVERY_ACTION.gcode"
RECOVERY_BASENAME="RECOVERY_ACTION.gcode"

{
    echo "; RECOVERY START"
    echo "M140 S$TEMP_CAMA"
    echo "M104 S$TEMP_EXTRUSOR"
    echo "M190 S$TEMP_CAMA"
    echo "M109 S$TEMP_EXTRUSOR"
    echo "$FAN_CMD"
    echo "G90"
    echo "M83"
    
    # Subida de seguridad
    SAFE_Z=$(awk "BEGIN {print $POS_Z + 2.0}")
    echo "G1 Z$SAFE_Z F3000"
    
    if [ -n "$TARGET_X" ] || [ -n "$TARGET_Y" ]; then
        echo "G1 $TARGET_X $TARGET_Y F6000"
    fi
    
    echo "G1 Z$POS_Z F3000"
    echo "_PLR_AFTER_RECOVERY_ACTIONS"
    
    tail -c +"$FINAL_BYTE" "$FULLPATH"
} > "$NUEVO"

# --- Notificar ---
if [ -f "$NUEVO" ]; then
    nohup curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"script\": \"M23 $RECOVERY_BASENAME\nM24\"}" \
      "$MOONRAKER_URL/printer/gcode/script" >/dev/null 2>&1 &
    echo "Success: Archivo generado."
else
    echo "ERROR: Falló la creación."
fi
