import threading
from spectrulenpor_console.udp import UdpStreamClient
from spectrulenpor_console.protocol import CMD_SHUTDOWN

messages = []
peer_ready = threading.Event()
shutdown_ack = threading.Event()

def on_message(message):
    messages.append(message)
    if message.startswith("$CMD:shutdown_complete"):
        shutdown_ack.set()

client = UdpStreamClient(
    on_state=lambda state: peer_ready.set() if state == "connected" else None,
    on_message=on_message,
)
try:
    client.start("192.138.1.2")
    if not peer_ready.wait(8):
        raise SystemExit("ESP32 did not register the UDP peer")
    print("UDP peer:", client.peer, flush=True)
    client.send_command(CMD_SHUTDOWN)
    if not shutdown_ack.wait(5):
        raise SystemExit("ESP32 did not acknowledge shutdown; no erase attempted")
    print("ESP32 ACK:", next(item for item in messages if item.startswith("$CMD:shutdown_complete")), flush=True)
    print("Control messages:", messages[:8], flush=True)
finally:
    client.close()
