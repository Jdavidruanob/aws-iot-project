import os
import time
import json
from datetime import datetime, timezone
import random
import paho.mqtt.client as mqtt

MQTT_HOST = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT = int(os.environ.get("MQTT_PORT", 1883))
CLIENT_ID = os.environ.get("CLIENT_ID", f"sensor-{random.randint(1000,9999)}")
SENSOR_TYPE = os.environ.get("SENSOR_TYPE", "temperature")
INTERVAL = int(os.environ.get("INTERVAL", 5))

TOPIC = "lab/sensors/data"

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"[{CLIENT_ID}] Conectado al broker MQTT en {MQTT_HOST}:{MQTT_PORT}")
    else:
        print(f"[{CLIENT_ID}] Error al conectar. Código: {rc}")

def generate_sensor_data():
    if SENSOR_TYPE == "temperature":
        # Temperatura en grados Celsius (rango normal interior)
        value = round(random.uniform(20.0, 40.0), 2)
    elif SENSOR_TYPE == "humidity":
        # Humedad relativa en porcentaje
        value = round(random.uniform(40.0, 80.0), 2)
    elif SENSOR_TYPE == "co2":
        # Concentración de CO2 en ppm (partes por millón)
        # Normal exterior ~400ppm, interior con personas ~800-1200ppm
        value = round(random.uniform(400.0, 1500.0), 2)
    else:
        value = round(random.uniform(0.0, 100.0), 2)

    return {
        "device_id": CLIENT_ID,
        "sensor_type": SENSOR_TYPE,
        "value": value,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }

def main():
    print(f"[{CLIENT_ID}] Iniciando sensor tipo '{SENSOR_TYPE}'...")

    client = mqtt.Client(client_id=CLIENT_ID)
    client.on_connect = on_connect

    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, 60)
            break
        except Exception as e:
            print(f"[{CLIENT_ID}] Esperando broker {MQTT_HOST}:{MQTT_PORT}... {e}")
            time.sleep(2)

    client.loop_start()

    try:
        while True:
            payload = generate_sensor_data()
            print(f"[{CLIENT_ID}] Publicando: {payload}")
            client.publish(TOPIC, json.dumps(payload), qos=1)
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print(f"\n[{CLIENT_ID}] Deteniendo sensor...")
    finally:
        client.loop_stop()
        client.disconnect()

if __name__ == '__main__':
    main()
