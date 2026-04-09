#!/bin/bash

# --- Configuración de rutas ---
PRINTER_DATA_DIR="/home/pi/printer_data/gcodes"
MOONRAKER_URL="http://127.0.0.1:7125"

DEFAULT_TEMP_CAMA=60
DEFAULT_TEMP_EXTRUSOR=200
DEFAULT_FAN_CMD="M107"

# --- Argumentos ---
FICHERO="$1"
BYTE_POS="$2"
POS_Z="$3"
FULLPATH="$PRINTER_DATA_DIR/$FICHERO"

if [ -z "$FICHERO" ] || [ -z "$BYTE_POS" ]; then
    echo "ERROR: Argumentos insuficientes"
    exit 1
fi

# 1. AJUSTE DE SEGURIDAD: Encontrar el inicio de la línea
# Leemos un pequeño bloque (64 bytes) antes del BYTE_POS y buscamos el último salto de línea
# Esto garantiza que el puntero se mueva al principio de la línea donde ocurrió el fallo.
AJUSTE_BYTE=$(head -c "$BYTE_POS" "$FULLPATH" | grep -aob "$" | tail -1 | cut -d: -f1)

if [ -n "$AJUSTE_BYTE" ]; then
    # El nuevo punto de inicio es justo después del último salto de línea encontrado
    FINAL_BYTE=$((AJUSTE_BYTE + 1))
else
    # Si no hay salto de línea previo (muy raro), usamos el original
    FINAL_BYTE=$BYTE_POS
fi

# 2. Obtener el encabezado completo hasta el punto ajustado
HEADER_CHUNK=$(head -c "$FINAL_BYTE" "$FULLPATH")

# 3. EXTRAER METADATOS (Header, Thumbnails, Exclude Objects)
HEADERS=$(echo "$HEADER_CHUNK" | sed -n '/; HEADER_BLOCK_START/,/; HEADER_BLOCK_END/p')
THUMBNAILS=$(echo "$HEADER_CHUNK" | sed -n '/; THUMBNAIL_BLOCK_START/,/; THUMBNAIL_BLOCK_END/p')
EXCLUDE_OBJECTS=$(echo "$HEADER_CHUNK" | grep "EXCLUDE_OBJECT_DEFINE")

# 4. Buscar parámetros de estado
TOTAL_LAYER=$(echo "$HEADER_CHUNK" | grep "SET_PRINT_STATS_INFO TOTAL_LAYER" | tail 0)
CURRENT_LAYER=$(echo "$HEADER_CHUNK" | grep "SET_PRINT_STATS_INFO CURRENT_LAYER" | tail -1)
TEMP_CAMA=$(echo "$HEADER_CHUNK" | grep -E "M190|M140" | tail -1 | grep -oP "S[0-9.]+" | tr -d 'S')
TEMP_EXTRUSOR=$(echo "$HEADER_CHUNK" | grep -E "M109|M104" | tail -1 | grep -oP "S[0-9.]+" | tr -d 'S')
FAN_CMD=$(echo "$HEADER_CHUNK" | grep -E "M106|M107" | tail -1)

[ -z "$TEMP_CAMA" ] && TEMP_CAMA=$DEFAULT_TEMP_CAMA
[ -z "$TEMP_EXTRUSOR" ] && TEMP_EXTRUSOR=$DEFAULT_TEMP_EXTRUSOR
[ -z "$FAN_CMD" ] && FAN_CMD="$DEFAULT_FAN_CMD"

# --- Crear archivo de recuperación ---
DIRNAME=$(dirname "$FULLPATH")
BASENAME=$(basename "$FULLPATH")
NUEVO="${DIRNAME}/RECOVERY_${BASENAME}"
RECOVERY_BASENAME=$(basename "$NUEVO")

{
    echo "; ##################################################"
    echo "; # PLR RECOVERY - SAFE LINE START                 #"
    echo "; ##################################################"
    
    [ -n "$HEADERS" ] && echo "$HEADERS"
    [ -n "$THUMBNAILS" ] && echo "$THUMBNAILS"
    [ -n "$EXCLUDE_OBJECTS" ] && echo "$EXCLUDE_OBJECTS"

    echo "M190 S$TEMP_CAMA"
    echo "M109 S$TEMP_EXTRUSOR"
    echo "$FAN_CMD"
        
    echo "G90 ; Absolutas"
    echo "M83 ; Extrusión relativa"
    echo "G1 Z$POS_Z F3000"
    
    echo "_PLR_AFTER_RECOVERY_ACTIONS"
    echo "; --- DATA START ---"

    # Retomar desde el byte ajustado al inicio de línea
    tail -c +"$FINAL_BYTE" "$FULLPATH"

} > "$NUEVO"

# --- Notificar a Moonraker ---
if [ -f "$NUEVO" ]; then
    nohup curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"script\": \"_PLR_AUTO_PRINT_RECOVERY FILE=\\\"${RECOVERY_BASENAME}\\\"\"}" \
      "$MOONRAKER_URL/printer/gcode/script" >/dev/null 2>&1 &
    echo "Success: Archivo generado comenzando en línea limpia."
else
    echo "ERROR"
    exit 1
fi
