# 🚀 Klipper Power Loss Recovery (PLR) - Sistema de Rescate Pro

Este repositorio contiene una solución avanzada de **Recuperación ante Pérdida de Energía (PLR)** para impresoras 3D con firmware Klipper. A diferencia de otros métodos, este sistema utiliza un script de Python para analizar el archivo G-code original y generar un nuevo archivo de rescate que mantiene el estado exacto de la impresión.

## 📂 Componentes del Sistema

El sistema se divide en tres partes fundamentales:

* **`klipper_macros.cfg`**: Gestiona la lógica dentro de Klipper, incluyendo el guardado de variables persistentes, el monitoreo del estado de impresión y el menú interactivo de recuperación.
* **`plr_resume.py`**: Script de Python que procesa el G-code, alinea los bytes al inicio de línea, recupera temperaturas, ventiladores, capas y genera el archivo de continuación.
* **`shell_command.cfg`**: Permite que Klipper ejecute el script de Python desde el terminal de Linux.

## ✨ Características Principales

* **Monitoreo Inteligente (`PLR_TICKER`)**: Registra la posición del archivo, el offset de Z y la altura actual cada 15 segundos para minimizar el desgaste del almacenamiento.
* **Recuperación Completa de Estado**: El script recupera automáticamente:
    * Temperaturas de cama y extrusor.
    * Velocidad del ventilador de capa (`M106/M107`).
    * Estado de capas (`TOTAL_LAYER` y `CURRENT_LAYER`).
    * Configuración de *Pressure Advance* y objetos excluidos (`Exclude Objects`).
* **Homing Seguro (`_PLR_HOME_SURE`)**: Realiza homing de los ejes X e Y de forma segura, evitando colisiones con la pieza que ya está en la cama.
* **Interfaz Interactiva**: Muestra un menú en la pantalla de la impresora y envía alertas (compatible con Telegram) al detectar un fallo tras el reinicio.

## 🛠️ Requisitos e Instalación

1.  **Plugin de Comandos Shell**: Debes tener instalado `gcode_shell_command` (generalmente a través de KIAUH).
2.  **Configuración de Variables**: Asegúrate de tener habilitado el bloque de variables persistentes en tu `printer.cfg`:
    ```ini
    [save_variables]
    filename: ~/printer_data/config/variables.cfg
    ```
3.  **Integración**: Copia los archivos en tu carpeta de configuración e inclúyelos en tu archivo principal:
    ```ini
    [include klipper_macros.cfg]
    [include shell_command.cfg]
    ```

## 🚀 Cómo utilizarlo

### 1. Configuración en el Slicer (Laminador)
Debes añadir las macros correspondientes en los ajustes de tu laminador para que el sistema sepa cuándo empezar y cuándo limpiar los datos:

* **Start G-code**: Añade `_PLR_PRINT_START`.
* **End G-code**: Añade `_PLR_STOP`.
* **Before Layer Change**: Añade `_PLR_Z` (opcional, para mayor precisión de altura).

### 2. En caso de fallo de energía
1.  Enciende la impresora.
2.  Aparecerá un mensaje automático: **"¿Deseas retomar la impresión desde la última capa guardada?"**.
3.  Selecciona **CONTINUAR**. La impresora:
    * Analizará el archivo original.
    * Generará un nuevo archivo llamado `[nombre]_recovery.gcode`.
    * Calentará los componentes y reanudará la impresión automáticamente.

## ⚠️ Advertencias
* **Adherencia**: Si la cama se enfría por completo, la pieza podría despegarse, haciendo imposible la recuperación.
* **Movimiento Manual**: Si mueves los ejes manualmente mientras la impresora está apagada, la precisión del rescate se verá afectada.

---
**Autor:** [joseto1298](https://github.com/joseto1298)
