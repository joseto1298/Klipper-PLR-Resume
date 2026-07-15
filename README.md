# Klipper Power Loss Recovery (PLR) - Sistema de Rescate Pro

Sistema avanzado de **Recuperación ante Pérdida de Energía (PLR)** para impresoras 3D con firmware Klipper. Analiza el G-code original y genera un archivo de rescate que mantiene el estado exacto de la impresión.

---

## Mapa de Archivos

```
Klipper-PLR-Resume/
│
├── klipper_macros.cfg     ← 12 macros (el cerebro lógico)
│   ├── _PLR_PRINT_START         (inicio impresión)
│   ├── _PLR_STOP                (fin exitoso)
│   ├── _PLR_Z                   (guarda Z puntual)
│   ├── _PLR_PAUSE               (pausa)
│   ├── _PLR_RESUME              (reanudar)
│   ├── _PLR_CHECK               (verifica al arrancar)
│   ├── _PLR_FAILURE_ALERT       (menú de alerta)
│   ├── _PLR_CANCEL_PRINT_RECOVERY  (cancelar)
│   ├── _PLR_RECOVERY            (llama al script)
│   ├── _PLR_HOME_SURE           (homing seguro)
│   ├── _PLR_AUTO_PRINT_RECOVERY (arranca recovery)
│   ├── _PLR_AFTER_RECOVERY_ACTIONS (purge+clean)
│   └── PLR_TICKER               (timer cada 15s)
│
├── plr_resume.py          ← Script Python (procesa G-code)
├── shell_command.cfg      ← Puente Klipper -> Linux
├── requirements.txt       ← Dependencia: requests
└── .gitignore
```

---

## Cómo Funciona

### 1. Flujo Normal (impresión sin fallos)

```
 slicer Start G-code                    slicer End G-code
       │                                      │
       ▼                                      ▼
 ┌─────────────┐                       ┌───────────┐
 │_PLR_PRINT_  │                       │_PLR_STOP  │
 │   START     │                       │           │
 └──────┬──────┘                       └─────┬─────┘
        │                                    │
        ▼                                    ▼
 ┌─────────────┐                       ┌───────────┐
 │ plr_activate│                       │plr_activate│
 │    = True   │                       │   = False  │
 │ plr_file =  │                       │ plr_data = │
 │ "file.gcode"│                       │  "0,0,0"  │
 └──────┬──────┘                       └─────┬─────┘
        │                                    │
        ▼                                    ▼
 ┌─────────────┐                       ┌───────────┐
 │ PLR_TICKER  │   cada 15s           │PLR_TICKER │
 │ cada 15s    │ ──────────────────►  │ DURATION=0│
 │ guarda:     │   guarda:            │  (detiene)│
 │ plr_data =  │   plr_data =        └───────────┘
 │ "pos,z,z"   │   "nueva_pos,z,z"
 └─────────────┘
```

### 2. Flujo de Fallo

```
        IMPRESIÓN EN CURSO
               │
    PLR_TICKER cada 15s
    guarda en variables.cfg:
    plr_data = "123456,0.15,5.2"
               │
               ▼
        ⚡ FALLO ⚡
        (se apaga)
               │
    variables.cfg SOBREVIVE en disco
    (plr_activate=True, plr_data="123456,0.15,5.2")
               │
               ▼
     ════════════════════════
      REINICIO DE LA IMPRESORA
     ════════════════════════
               │
               ▼
        ┌─────────────┐
        │  _PLR_CHECK │  ← delayed_gcode al arrancar
        └──────┬──────┘
               │
               ▼
        ┌──────────────┐
        │plr_activate  │
        │   == True?   │
        └──┬───────┬───┘
           │       │
          SÍ      NO
           │       │
           ▼       ▼
    ┌──────────────┐  (nada)
    │_PLR_FAILURE  │
    │   _ALERT     │
    └──────┬───────┘
           │
           ▼
    ┌──────────────────────────────┐
    │  ⚠️ Se interrumpió          │
    │  la impresión.              │
    │                             │
    │  ¿Deseas retomar desde      │
    │  la última capa guardada?   │
    │                             │
    │  [CONTINUAR] [CANCELAR]     │
    └──────┬───────────┬──────────┘
           │           │
           ▼           ▼
    ┌──────────┐  ┌────────────────┐
    │_PLR_     │  │_PLR_CANCEL_    │
    │RECOVERY  │  │PRINT_RECOVERY  │
    └────┬─────┘  └───────┬────────┘
         │                │
         ▼                ▼
    (sigue abajo)    ┌─────────┐
                     │_PLR_STOP│
                     └─────────┘
```

### 3. Flujo de Recuperación (CONTINUAR)

```
    ┌──────────┐
    │_PLR_     │
    │RECOVERY  │
    └────┬─────┘
         │
         │  Lee de variables.cfg:
         │  plr_file = "mi_pieza.gcode"
         │  plr_data = "123456,0.15,5.2"
         │
         │  Parsea:
         │  file_pos = 123456
         │  z_offset = 0.15
         │  z_pos = 5.2
         │
         ▼
    ┌──────────────────────────────────┐
    │  RUN_SHELL_COMMAND               │
    │  CMD=PLR_RESUME                  │
    │  PARAMS='"file" 123456 5.2 0.15' │
    └──────────────┬───────────────────┘
                   │
                   │  shell_command.cfg traduce a:
                   │  ~/venv/bin/python3 ~/plr_resume.py "file" 123456 5.2 0.15
                   ▼
    ╔══════════════════════════════════════╗
    ║         plr_resume.py                ║
    ║         (Script Python)              ║
    ╚══════════════════════════════════════╝
                   │
```

### 4. Interior de plr_resume.py

```
    Entrada: "mi_pieza.gcode" 123456 5.2 0.15
                    │
    ╔═══════════════╧═══════════════╗
    ║  1. ALINEAR BYTE              ║
    ║                               ║
    ║  G1 X150 Y100 E0.5 F1200\n   ║
    ║                    ↑ 123456   ║
    ║                    │          ║
    ║  Retrocede hasta \n           ║
    ║                    │          ║
    ║  G1 X150 Y100 E0.5 F1200\n   ║
    ║                         ↑ byte_limpio
    ╚═══════════════╤═══════════════╝
                    │
    ╔═══════════════╧═══════════════╗
    ║  2. EXTRAER METADATOS         ║
    ║                               ║
    ║  headers     ← HEADER_BLOCK   ║
    ║  thumbnails  ← THUMBNAIL_BLOCK║
    ║  excl.objects← EXCLUDE_OBJECT ║
    ╚═══════════════╤═══════════════╝
                    │
    ╔═══════════════╧═══════════════╗
    ║  3. EXTRAER ESTADO            ║
    ║                               ║
    ║  Busca HACIA ATRÁS desde      ║
    ║  byte 123456:                 ║
    ║                               ║
    ║  temp_cama  ← M140 S60        ║
    ║  temp_extru ← M104 S200       ║
    ║  fan        ← M106 S255       ║
    ║  total_layer← TOTAL_LAYER=50  ║
    ║  curr_layer ← CURRENT_LAYER=23║
    ║  pa         ← PA ADVANCE=0.04 ║
    ║  tool       ← T0              ║
    ║  filament   ← FILAMENT ID=0   ║
    ║  e_mode     ← M83             ║
    ║  feedrate   ← G1 ... F6000    ║
    ║  m220       ← M220 S100       ║
    ╚═══════════════╤═══════════════╝
                    │
    ╔═══════════════╧═══════════════╗
    ║  4. CALCULAR Z SEGURA         ║
    ║                               ║
    ║  z_max_objeto = 5.2           ║
    ║  z_max_maquina = 260          ║
    ║  extruder_clearance = 40      ║
    ║                               ║
    ║  z_segura = min(5.2+2, 260-2) ║
    ║          = min(7.2, 258)      ║
    ║          = 7.2                ║
    ║                               ║
    ║  Si 40 > 7.2:                 ║
    ║    z_segura = 40 + 2 = 42     ║
    ╚═══════════════╤═══════════════╝
                    │
    ╔═══════════════╧═══════════════╗
    ║  5. GENERAR _recovery.gcode   ║
    ╚═══════════════╤═══════════════╝
                    │
                    ▼
```

### 5. Estructura del Archivo _recovery.gcode

```
┌─────────────────────────────────────────┐
│ ; METADATA RECOVERY                     │
│                                         │
│ ; HEADER_BLOCK_START                    │
│ ; (config slicer: nozzle, bed, speed..) │
│ ; HEADER_BLOCK_END                      │
│                                         │
│ ; THUMBNAIL_BLOCK_START                 │
│ ; (imagen preview en base64)            │
│ ; THUMBNAIL_BLOCK_END                   │
│                                         │
│ EXCLUDE_OBJECT_DEFINE NAME=cubo ...     │
│ EXCLUDE_OBJECT_DEFINE NAME=esfera ...   │
├─────────────────────────────────────────┤
│ ; RECOVERY CONFIG                       │
│                                         │
│ T0                                     │  ← restaura herramienta
│ ASSERT_ACTIVE_FILAMENT ID=0            │  ← restaura filamento
│ SET_PRINT_STATS_INFO TOTAL_LAYER=50    │  ← restaura total capas
│ SET_PRINT_STATS_INFO CURRENT_LAYER=23  │  ← restaura capa actual
│ SET_PRESSURE_ADVANCE ADVANCE=0.04      │  ← restaura PA
│ EXCLUDE_OBJECT_START NAME=cubo         │  ← restaura objeto activo
│ SET_GCODE_OFFSET Z=0.15                │  ← restaura baby stepping
│                                         │
│ _PLR_HOME_SURE Z_UP=42 Z_POS=5.2      │  ← homing seguro
├─────────────────────────────────────────┤
│ ; CALIENTAMIENTO                        │
│                                         │
│ M106 S255                              │  ← ventilador
│ M140 S60                               │  ← inicia cama
│ M104 S200                              │  ← inicia extrusor
│ M190 S60                               │  ← ESPERA cama
│ M109 S200                              │  ← ESPERA extrusor
├─────────────────────────────────────────┤
│ ; PREPARACIÓN                           │
│                                         │
│ G90                                    │  ← coordenadas absolutas
│ M83                                    │  ← extrusor relativo
│                                         │
│ _PLR_AFTER_RECOVERY_ACTIONS            │
│   ├── PURGE_NOZZLE                     │  ← purga boquilla
│   ├── CLEAN_NOZZLE                     │  ← limpia
│   ├── _ENABLE_AI_MONITOR               │  ← reactiva IA
│   └── _PLR_PRINT_START                 │  ← reinicia tracking
├─────────────────────────────────────────┤
│ ; MOVIMIENTO AL PUNTO DE FALLO          │
│                                         │
│ G1 X150 Y100 F6000                    │  ← XY del fallo
│                                         │
│     ┌───────────────────┐              │
│     │  Boquilla en      │              │
│     │  Z=42 (segura)    │  Z=42        │
│     │         │         │              │
│     │         ▼         │              │
│     │  G1 Z7.2 F3000    │  Z=7.2 (+2mm│
│     │  (desc. rápido)   │   sobre pieza│
│     │         │         │              │
│     │         ▼         │              │
│     │  G1 Z5.2 F300     │  Z=5.2 (exacta)
│     │  (desc. lento)    │              │
│     │         │         │              │
│     │    ▓▓▓▓▓▓▓▓▓▓▓   │  ← pieza     │
│     │    ▓▓▓▓▓▓▓▓▓▓▓   │              │
│     └───────────────────┘              │
├─────────────────────────────────────────┤
│ ; SINCRONIZACIÓN EXTRUSIÓN              │
│                                         │
│ Si M82 (absoluto):                      │
│   G92 E12.5    ← sincroniza acumulado  │
│   M82          ← modo absoluto         │
│                                         │
│ Si M83 (relativo):                      │
│   G92 E0       ← resetea a 0           │
│   M83          ← modo relativo         │
├─────────────────────────────────────────┤
│ ; RESTAURAR VELOCIDAD                   │
│                                         │
│ M220 S120       ← override velocidad   │
│                  (solo si ≠ 100)        │
│ G1 F6000        ← feedrate base        │
│                  (extraído del G-code)  │
├─────────────────────────────────────────┤
│ ; CONTINUACIÓN ORIGINAL                 │
│                                         │
│ (todo el G-code desde byte 123456)      │
│                                         │
│ G1 X155 Y105 E0.5 F1200               │
│ G1 X160 Y110 E0.8 F1200               │
│ ...                                    │
└─────────────────────────────────────────┘
```

### 6. Cómo Busca el Estado (buscar_ultimo_estado)

```
Archivo G-code completo:

[──────────────────────|123456|──────────────────]
                        ↑ corte

Busca EN REVERSO desde el corte:

Paso 1:  Lee chunk de 64KB ← [57920..123456]
         Busca "M1[49]0.*?S(\d+)"
         ¿Encontró? → SÍ → "M140 S60" → retorna "60"

Paso 2:  Si no encontró, sigue ← [0..57920]
         Busca de nuevo

         ┌──────────────────────────────┐
         │ Si encontró en paso 1,       │
         │ NO busca más (es el más      │
         │ cercano al corte = el más    │
         │ reciente)                    │
         └──────────────────────────────┘
```

### 7. Variables Persistentes

```
┌─────────────────────────────────────────────┐
│  variables.cfg  (sobrevive reinicios)       │
│                                             │
│  plr_activate = True/False                  │
│  plr_file = "mi_pieza.gcode"                │
│  plr_data = "123456,0.15,5.2"              │
│              │     │    │                   │
│              │     │    └─ Z real (5.2mm)   │
│              │     └────── Z offset (0.15)  │
│              └──────────── byte pos         │
│  plr_z = 5.2                               │
│                                             │
│  ¿Quién escribe?  ¿Quién lee?              │
│  ────────────────  ───────────              │
│  PLR_TICKER       _PLR_RECOVERY             │
│  _PLR_PAUSE        plr_resume.py            │
│  _PLR_PRINT_START                           │
│  _PLR_STOP                                  │
│  _PLR_RESUME                                │
└─────────────────────────────────────────────┘
```

### 8. Timeline Completo

```
Normal          Fallo       Recuperación
  │               │               │
  │  PLR_TICKER   │               │
  │  cada 15s     │               │
  │  ↓            │               │
  │  variables.cfg│               │
  │  guardando    │               │
  │  ↓            │               │
  │  ↓         ⚡ APAGADO ⚡       │
  │  ↓            │               │
  │  ↓       ┌────┴────┐          │
  │  ↓       │disk safe│          │
  │  ↓       └────┬────┘          │
  │  ↓            │      REINICIO │
  │  ↓            │          │    │
  │  ↓      _PLR_CHECK       │    │
  │  ↓            │          │    │
  │  ↓      plr_activate=True│    │
  │  ↓            │          │    │
  │  ↓      _PLR_FAILURE_ALERT    │
  │  ↓            │          │    │
  │  ↓       [CONTINUAR]     │    │
  │  ↓            │          │    │
  │  ↓      _PLR_RECOVERY    │    │
  │  ↓            │          │    │
  │  ↓      plr_resume.py    │    │
  │  ↓      genera:          │    │
  │  ↓      _recovery.gcode  │    │
  │  ↓            │          │    │
  │  ↓      POST Moonraker   │    │
  │  ↓            │          │    │
  │  ↓      _PLR_HOME_SURE   │    │
  │  ↓      Calienta         │    │
  │  ↓      Purge            │    │
  │  ↓      Movimiento XY    │    │
  │  ↓      Descenso Z       │    │
  │  ↓      Sincroniza E     │    │
  │  ↓            │          │    │
  │  ↓      CONTINÚA G-code  │    │
  │  ↓      desde byte 123456│    │
```

---

## Requisitos e Instalación

1. **Plugin de Comandos Shell**: Instala `gcode_shell_command` (via KIAUH).
2. **Variables Persistentes** en `printer.cfg`:
   ```ini
   [save_variables]
   filename: ~/printer_data/config/variables.cfg
   ```
3. **Boot Check** en `printer.cfg` (para detectar fallo al arrancar):
   ```ini
   [delayed_gcode _PLR_BOOT_CHECK]
   initial_duration: 1
   gcode:
       _PLR_CHECK
   ```
4. **Integrar archivos**:
   ```ini
   [include klipper_macros.cfg]
   [include shell_command.cfg]
   ```
5. **Instalar dependencia**:
   ```bash
   cd ~/Klipper-PLR-Resume
   source venv/bin/activate
   pip install -r requirements.txt
   ```

## Configuración del Slicer

* **Start G-code**: `_PLR_PRINT_START`
* **End G-code**: `_PLR_STOP`
* **Before Layer Change**: `_PLR_Z` (opcional, mayor precisión)

## En caso de fallo de energía

1. Enciende la impresora.
2. Aparece el mensaje: **"¿Deseas retomar la impresión desde la última capa guardada?"**
3. Selecciona **CONTINUAR**. La impresora genera el archivo `_recovery.gcode` y reanuda automáticamente.

## Advertencias

* **Adherencia**: Si la cama se enfría por completo, la pieza podría despegarse.
* **Movimiento Manual**: Si mueves los ejes manualmente mientras está apagada, la precisión se verá afectada.

---
**Autor:** [joseto1298](https://github.com/joseto1298)
