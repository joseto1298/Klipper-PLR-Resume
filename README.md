# Klipper-PLR-Resume: Recuperación de Impresiones 3D Interrumpidas

Sistema completo para la **recuperación automática y manual de impresiones 3D interrumpidas** en Klipper. Esta solución combina macros de Klipper (`.cfg`) y un script de shell (`.sh`) para generar un archivo de recuperación optimizado (re-corte del G-code) basado en las últimas coordenadas (X, Y, Z) guardadas, y reinicia la impresión a través de Moonraker.

## 🌟 Características Principales

*   **Recuperación Automática y Manual:** Permite reanudar una impresión fallida o interrumpida, ya sea por un corte de energía o otro tipo de fallos.
*   **Re-corte Inteligente del G-code:** El script de shell (`plr_resume.sh`) analiza el archivo G-code original y lo "re-corta" a partir de la última coordenada Z guardada, creando un nuevo archivo de recuperación optimizado.
*   **Guardado de Posición Persistente:** Las macros de Klipper guardan la posición Z actual en variables persistentes, asegurando que la información se mantenga incluso después de un reinicio.
*   **Notificación de Fallo:** Incluye una macro para notificar al usuario a través de la interfaz (Moonraker/Mainsail/Fluidd) y Telegram (si está configurado) cuando se detecta un fallo.
*   **Restauración de Parámetros:** El script de recuperación intenta restaurar parámetros importantes como la temperatura de la cama y el extrusor, el estado del ventilador, el *spool* activo y la capa actual/total.

## ⚙️ Componentes del Repositorio

| Fichero | Descripción | Función Principal |
| :--- | :--- | :--- |
| `klipper_macros.cfg` | Archivo de configuración de Klipper | Contiene las macros G-code para el control de la lógica de recuperación, guardado de posición y notificaciones. |
| `plr_resume.sh` | Script de Shell (Bash) | Ejecuta la lógica de re-corte del G-code, determina los parámetros de impresión a restaurar y envía la orden de reinicio a Moonraker. |
| `shell_command.cfg` | Configuración de Klipper | Define el comando de shell que Klipper ejecutará para invocar el script `plr_resume.sh`. |

## 🛠️ Instalación y Configuración

### 1. Copiar Archivos

Copie los archivos `klipper_macros.cfg`, `plr_resume.sh` y `shell_command.cfg` en su directorio de configuración de Klipper (por ejemplo, `/home/pi/klipper_config/`).

### 2. Configuración de Klipper

Añada las siguientes líneas a su archivo `printer.cfg` para incluir los archivos de configuración:

```cfg
[include klipper_macros.cfg]
[include shell_command.cfg]
```

### 3. Configuración del Script (`plr_resume.sh`)

Edite el script `plr_resume.sh` para ajustar las variables de entorno si es necesario:

| Variable | Descripción | Valor por Defecto |
| :--- | :--- | :--- |
| `PRINTER_DATA_DIR` | Directorio donde Klipper guarda los G-codes. | `/home/pi/printer_data/gcodes` |
| `MOONRAKER_URL` | URL de la API de Moonraker. | `http://127.0.0.1:7125` |
| `DEFAULT_TEMP_CAMA` | Temperatura de cama por defecto para la recuperación. | `60` |
| `DEFAULT_TEMP_EXTRUSOR` | Temperatura de extrusor por defecto para la recuperación. | `200` |
| `DEFAULT_FAN_CMD` | Comando del ventilador por defecto. | `M107` |

### 4. Configuración de `shell_command.cfg`

Asegúrese de que la ruta al script `plr_resume.sh` en `shell_command.cfg` sea correcta. El comando definido es:

```cfg
[gcode_shell_command PLR_RESUME_SCRIPT]
command: /home/pi/Klipper-PLR-Resume/plr_resume.sh
timeout: 30
verbose: True
```
### 5. Configuración de `moonraker.conf`

Añadir para buscar actualizaciones.

```
[update_manager Klipper-PLR-Resume]
type: git_repo
primary_branch: main
path: /home/pi/Klipper-PLR-Resume
origin: https://github.com/joseto1298/Klipper-PLR-Resume.git
managed_services: klipper
```

**Nota:** Reemplace `/home/pi/Klipper-PLR-Resume` con la ruta absoluta donde ha guardado el script.

## 🚀 Uso de las Macros

Las macros principales que utilizará son:

| Macro | Descripción | Uso |
| :--- | :--- | :--- |
| `PLR_PRINT_START` | Inicia una impresión con el sistema de recuperación activado. **Debe añadirse en g-code de inicio del laminador.** | `PLR_PRINT_START` |
| `PLR_PAUSE` | Pausa la impresión y guarda la posición Z actual. | `PLR_PAUSE` |
| `PLR_STOP` | Detiene la impresión y desactiva el sistema de recuperación. | `PLR_STOP` |
| `PLR_RESUME` | Reanuda la impresión a partir de la última posición guardada. | `PLR_RESUME` |
| `PLR_AUTO_PRINT_RECOVERY` | Inicia la impresión de recuperación desde un fichero G-code específico. **Usada internamente por el script de shell.** | `PLR_AUTO_PRINT_RECOVERY FILE=<nombre_fichero.gcode>` |

### Integración en el G-code de Inicio

Para activar la recuperación de pérdida de energía, debe asegurarse de añadir la macro al g-code de inicio del laminador. `PLR_PRINT_START`.

```cfg
gcode:
    # ... comandos de homing, calentamiento, etc.
    PLR_PRINT_START
    # ... comandos de purga, etc.
```

## 📝 Funcionamiento del Script (`plr_resume.sh`)

El script se ejecuta cuando se llama a la macro `PLR_AUTO_PRINT_RECOVERY`. Su función es:

1.  **Validar Argumentos:** Recibe el nombre del archivo G-code y la coordenada Z de recuperación.
2.  **Buscar la Marca de Recuperación:** Utiliza `grep` para encontrar la línea en el G-code original que corresponde a la coordenada Z guardada.
3.  **Extraer Parámetros:** Busca los últimos comandos de temperatura (`M140`, `M104`, `M190`, `M109`), ventilador (`M106`, `M107`) y otros parámetros de impresión (capa, *spool*, *pressure advance*) antes de la línea de corte.
4.  **Crear Archivo de Recuperación:** Genera un nuevo archivo G-code (`<nombre>_recovery.gcode`) que contiene:
    *   Comandos para restaurar temperaturas y parámetros.
    *   Comandos para moverse a la posición Z de recuperación.
    *   El resto del G-code original a partir de la línea de corte.
5.  **Reiniciar Impresión:** Envía una solicitud a la API de Moonraker para iniciar la impresión del nuevo archivo de recuperación.

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Consulte el archivo [LICENSE](LICENSE) para más detalles.
