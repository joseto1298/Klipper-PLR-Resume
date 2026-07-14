import sys
import os
import re
import logging
import requests

# --- CONFIGURACIÓN ---
PRINTER_DATA_DIR = os.environ.get("PLR_PRINTER_DATA_DIR", "/home/pi/printer_data/gcodes")
MOONRAKER_URL = os.environ.get("PLR_MOONRAKER_URL", "http://127.0.0.1:7125/printer/gcode/script")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [PLR] %(levelname)s: %(message)s")
logger = logging.getLogger("plr_resume")

def alinear_byte_a_inicio_linea(fullpath, byte_pos):
    try:
        with open(fullpath, 'rb') as f:
            if byte_pos <= 0: return 0
            current_pos = byte_pos
            f.seek(current_pos)
            while current_pos > 0:
                f.seek(current_pos - 1)
                char = f.read(1)
                if char in (b'\n', b'\r'):
                    return current_pos
                current_pos -= 1
            return 0
    except Exception as e:
        logger.error("Error alineando byte a inicio de línea: %s", e)
        return byte_pos

def obtener_proximo_movimiento(fullpath, byte_pos):
    try:
        with open(fullpath, 'rb') as f:
            f.seek(byte_pos)
            future_data = f.read(32768).decode('utf-8', errors='ignore')
            next_move = re.search(r'G[01].*(X[-+]?\d*\.?\d*|Y[-+]?\d*\.?\d*)', future_data)
            if next_move:
                line = next_move.group(0)
                x_match = re.search(r'X([-+]?\d*\.?\d*)', line)
                y_match = re.search(r'Y([-+]?\d*\.?\d*)', line)
                target = ""
                if x_match: target += f" X{x_match.group(1)}"
                if y_match: target += f" Y{y_match.group(1)}"
                return target
    except Exception as e:
        logger.error("Error obteniendo próximo movimiento: %s", e)
    return ""

def extraer_todos_los_bloques(fullpath, start_pattern, end_pattern, max_bytes=400000):
    bloques = []
    try:
        with open(fullpath, 'rb') as f:
            content = f.read(max_bytes).decode('utf-8', errors='ignore')
            regex = f"{re.escape(start_pattern)}.*?{re.escape(end_pattern)}"
            matches = re.finditer(regex, content, re.DOTALL)
            for match in matches:
                bloques.append(match.group(0))
        return "\n".join(bloques) + "\n" if bloques else ""
    except Exception as e:
        logger.error("Error extrayendo bloques (%s -> %s): %s", start_pattern, end_pattern, e)
        return ""

def extraer_lineas_grep(fullpath, pattern, max_bytes=300000):
    try:
        with open(fullpath, 'rb') as f:
            content = f.read(max_bytes).decode('utf-8', errors='ignore')
            lines = re.findall(f".*{re.escape(pattern)}.*", content)
            return "\n".join(lines) + "\n" if lines else ""
    except Exception as e:
        logger.error("Error extrayendo líneas con patrón '%s': %s", pattern, e)
        return ""

def buscar_desde_principio(fullpath, regex, max_bytes=150000, default=""):
    try:
        regex_compiled = re.compile(regex)
        with open(fullpath, 'rb') as f:
            chunk = f.read(max_bytes).decode('utf-8', errors='ignore')
            match = regex_compiled.search(chunk)
            return match.group(0).strip() if match else default
    except Exception as e:
        logger.error("Error buscando desde principio con regex '%s': %s", regex, e)
        return default

def buscar_desde_elfinal(fullpath, regex, max_bytes=1000000, default="250"):
    try:
        regex_compiled = re.compile(regex)
        with open(fullpath, 'rb') as f:
            f.seek(0, os.SEEK_END)
            file_size = f.tell()
            leer_desde = max(0, file_size - max_bytes)
            f.seek(leer_desde)
            chunk = f.read().decode('utf-8', errors='ignore')
            matches = list(regex_compiled.finditer(chunk))
            if matches:
                return matches[-1].group(0).strip()
    except Exception as e:
        logger.error("Error buscando desde el final con regex '%s': %s", regex, e)
    return default

def buscar_ultimo_estado(fullpath, start_byte, regex, default=""):
    regex_compiled = re.compile(regex)
    chunk_size = 65536
    current_pos = start_byte
    try:
        with open(fullpath, 'rb') as f:
            while current_pos > 0:
                read_size = min(current_pos, chunk_size)
                current_pos -= read_size
                f.seek(current_pos)
                chunk = f.read(read_size).decode('utf-8', errors='ignore')
                matches = list(regex_compiled.finditer(chunk))
                if matches: return matches[-1].group(0).strip()
    except Exception as e:
        logger.error("Error buscando último estado con regex '%s': %s", regex, e)
    return default

def buscar_z_maxima_hasta_corte(fullpath, byte_pos):
    z_max_encontrada = 0.0
    try:
        with open(fullpath, 'rb') as f:
            contenido_previo = f.read(byte_pos).decode('utf-8', errors='ignore')
            matches = re.findall(r'G[01].*?Z([0-9.]+)', contenido_previo)
            if matches:
                z_max_encontrada = max(float(z) for z in matches)
    except Exception as e:
        logger.error("Error buscando Z máxima hasta corte: %s", e)
    return z_max_encontrada

def generar_archivo_recuperacion(original_fullpath, filename, byte_pos, z_pos, estado, metadatos, z_offset):
    name_part, ext = os.path.splitext(filename)
    recovery_filename = f"{name_part}_recovery{ext}"
    recovery_fullpath = os.path.join(PRINTER_DATA_DIR, recovery_filename)

    byte_limpio = alinear_byte_a_inicio_linea(original_fullpath, byte_pos)

    # Obtener altura de máquina
    linea_altura = buscar_desde_elfinal(original_fullpath, r';\s*printable_height\s*=\s*([0-9.]+)', default="260")

    # Margen de altura entre la boquilla y el eje X (Para impresión por objetos)
    extruder_clearance_raw = buscar_desde_elfinal(original_fullpath, r';\s*extruder_clearance_height_to_rod\s*=\s*(\d+)', default="40")
    ec_match = re.search(r'(\d+)', extruder_clearance_raw)
    try:
        extruder_clearance = float(ec_match.group(1)) if ec_match else 40.0
    except (ValueError, AttributeError):
        extruder_clearance = 40.0

    alturas = re.findall(r'(\d+\.?\d*)', linea_altura)
    z_max_maquina = float(alturas[-1]) if alturas else 260.0

    # Determinar Z_UP real (Techo de todos los objetos impresos)
    z_max_objeto = buscar_z_maxima_hasta_corte(original_fullpath, byte_limpio)
    z_segura = min(z_max_objeto + 2, z_max_maquina - 2)

    if extruder_clearance > z_segura: z_segura = extruder_clearance + 2

    target_xy = obtener_proximo_movimiento(original_fullpath, byte_limpio)

    with open(recovery_fullpath, 'w', encoding='utf-8') as out:
        out.write("; ########## METADATA RECOVERY ##########\n")
        out.write(metadatos['headers'] + metadatos['thumbnails'] + metadatos['exclude_objects'])

        out.write("\n; ########## RECOVERY CONFIG ##########\n")
        if estado['tool']: out.write(f"{estado['tool']}\n")
        if estado['filament']: out.write(f"{estado['filament']}\n")
        if estado['total_layer']: out.write(f"{estado['total_layer']}\n")
        if estado['curr_layer']: out.write(f"{estado['curr_layer']}\n")
        if estado['pa']: out.write(f"{estado['pa']}\n")
        if estado['obj_activo']: out.write(f"{estado['obj_activo']}\n")
        out.write(f"SET_GCODE_OFFSET Z={z_offset}\n")

        out.write(f"_PLR_HOME_SURE Z_UP={z_segura} Z_POS={z_pos} \n")

        # Calentamiento
        out.write(f"{estado['fan']}\n")
        out.write(f"M140 S{estado['temp_cama']}\nM104 S{estado['temp_extru']}\n")
        out.write(f"M190 S{estado['temp_cama']}\nM109 S{estado['temp_extru']}\n")

        out.write("G90 ; Coordenadas Absolutas\n")
        out.write("M83 ; Extrusor Relativo para cebado\n")

        out.write("_PLR_AFTER_RECOVERY_ACTIONS\n")

        # Movimiento en L
        if target_xy:
            out.write(f"G1{target_xy} F6000\n")

        # Descenso a pieza
        out.write(f"G1 Z{z_pos + 2.0} F3000 ; Aproximación rápida\n")
        out.write(f"G1 Z{z_pos} F300 ; Aproximación lenta anti-impacto\n")

        # Sincronización de Extrusión
        if estado['e_mode'] == "M82":
            last_e = buscar_ultimo_estado(original_fullpath, byte_limpio, r'E(\d+\.?\d*)', "0")
            e_match = re.search(r'E(\d+\.?\d*)', last_e)
            e_val = e_match.group(1) if e_match else "0"
            out.write(f"G92 E{e_val}\nM82\n")
        else:
            out.write("G92 E0\nM83\n")

        out.write("\n; ########## CONTINUACIÓN ORIGINAL ##########\n")
        with open(original_fullpath, 'r', encoding='utf-8') as original:
            original.seek(byte_limpio)
            out.write(original.read())

    return recovery_filename

def main():
    if len(sys.argv) < 5:
        logger.error("Argumentos insuficientes. Uso: plr_resume.py <archivo> <byte_pos> <z_pos> <z_offset>")
        sys.exit(1)

    raw_byte, raw_z, raw_z_offset = sys.argv[-3], sys.argv[-2], sys.argv[-1]
    filename = " ".join(sys.argv[1:-3]).replace('"', '').strip()

    try:
        byte_pos = int(float(raw_byte))
        z_pos = float(raw_z)
        z_offset = float(raw_z_offset)
    except ValueError:
        logger.error("Error convirtiendo parámetros numéricos: byte=%s z=%s z_offset=%s", raw_byte, raw_z, raw_z_offset)
        sys.exit(1)

    fullpath = os.path.join(PRINTER_DATA_DIR, filename)
    if not os.path.exists(fullpath):
        logger.error("Archivo no encontrado: %s", fullpath)
        sys.exit(1)

    logger.info("Procesando recuperación: archivo=%s byte=%d z=%.2f z_offset=%.2f", filename, byte_pos, z_pos, z_offset)

    metadatos = {
        'headers': extraer_todos_los_bloques(fullpath, "; HEADER_BLOCK_START", "; HEADER_BLOCK_END"),
        'thumbnails': extraer_todos_los_bloques(fullpath, "; THUMBNAIL_BLOCK_START", "; THUMBNAIL_BLOCK_END"),
        'exclude_objects': extraer_lineas_grep(fullpath, "EXCLUDE_OBJECT_DEFINE")
    }

    estado = {
        'total_layer': buscar_desde_principio(fullpath, r'SET_PRINT_STATS_INFO TOTAL_LAYER=\d+', None),
        'curr_layer': buscar_ultimo_estado(fullpath, byte_pos, r'SET_PRINT_STATS_INFO CURRENT_LAYER=\d+'),
        'temp_cama': buscar_ultimo_estado(fullpath, byte_pos, r'M1[49]0.*?S([1-9]\d*(?:\.\d+)?)', None),
        'temp_extru': buscar_ultimo_estado(fullpath, byte_pos, r'M10[49].*?S([1-9]\d*(?:\.\d+)?)', None),
        'fan': buscar_ultimo_estado(fullpath, byte_pos, r'(M10[67][^;\n\r]*)', "M107"),
        'filament': buscar_ultimo_estado(fullpath, byte_pos, r'ASSERT_ACTIVE_FILAMENT\s+ID=\d+'),
        'pa': buscar_ultimo_estado(fullpath, byte_pos, r'SET_PRESSURE_ADVANCE\s+[^;\n\r]*'),
        'obj_activo': buscar_ultimo_estado(fullpath, byte_pos, r'EXCLUDE_OBJECT_START NAME=([^;\n\r]*)'),
        'tool': buscar_ultimo_estado(fullpath, byte_pos, r'^T\d+'),
        'e_mode': buscar_ultimo_estado(fullpath, byte_pos, r'(M8[23])', "M83"),
    }

    # Limpieza de temperaturas
    for k in ['temp_extru', 'temp_cama']:
        if estado.get(k):
            match = re.findall(r'(\d+\.?\d*)', str(estado[k]))
            estado[k] = match[-1] if match else None

    linea_start = buscar_desde_principio(fullpath, r'START_PRINT\s+.*', max_bytes=200000)

    if linea_start:
        if not estado["total_layer"]:
            l_match = re.search(r'LAYERCOUNT=(\d+)', linea_start)
            estado["total_layer"] = f"SET_PRINT_STATS_INFO TOTAL_LAYER={l_match.group(1)}"

        if not estado["temp_cama"]:
            b_match = re.search(r'BEDTEMPERATURE=(\d+)', linea_start)
            estado["temp_cama"] = b_match.group(1) if b_match else "60"

        if not estado["temp_extru"]:
            t_match = re.search(r'NOZZLETEMPERATURE=(\d+)', linea_start)
            estado["temp_extru"] = t_match.group(1) if t_match else "200"

    rec_file = generar_archivo_recuperacion(fullpath, filename, byte_pos, z_pos, estado, metadatos, z_offset)

    try:
        requests.post(MOONRAKER_URL, json={"script": f'_PLR_AUTO_PRINT_RECOVERY FILE="{rec_file}"'}, timeout=10)
        logger.info("Rescate exitoso: %s", rec_file)
    except Exception as e:
        logger.error("Archivo generado: %s (Error Moonraker: %s)", rec_file, e)
        sys.exit(1)

if __name__ == "__main__":
    main()
