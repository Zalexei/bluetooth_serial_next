// Echo firmware for testing bluetooth_serial_next.
//
// Commands, one per line, over Bluetooth (SPP) or the USB serial port:
//   ping        -> pong
//   info        -> chip, Bluetooth address, uptime
//   burst N     -> N letters A..Z as fast as possible, then "burst done N"
//   sink N      -> reads N bytes, then "sink done <got> in <ms> ms"
//   forget      -> forgets every paired phone (to test a lost pairing)
//   bye         -> drops the Bluetooth connection
//   anything    -> "echo: anything"
#include <Arduino.h>
#include <BluetoothSerial.h>

static BluetoothSerial bt;

struct Channel {
  Stream& io;
  String line;
};

static Channel channels[] = {{bt, ""}, {Serial, ""}};

static void burst(Stream& io, long count) {
  static uint8_t chunk[1024];
  for (long sent = 0; sent < count;) {
    const size_t n = min<long>(sizeof(chunk), count - sent);
    for (size_t i = 0; i < n; i++) chunk[i] = 'A' + (sent + i) % 26;
    io.write(chunk, n);
    sent += n;
  }
  io.printf("\nburst done %ld\n", count);
}

static void sink(Stream& io, long count) {
  static uint8_t buffer[4096];
  long got = 0;
  const uint32_t start = millis();
  uint32_t last = start;
  // Gives up after 3 s without data, so a short write does not hang it.
  while (got < count && millis() - last < 3000) {
    const int available = io.available();
    if (available <= 0) continue;
    const size_t want = min<long>(min<long>(available, sizeof(buffer)), count - got);
    got += io.readBytes(buffer, want);
    last = millis();
  }
  io.printf("sink done %ld in %lu ms\n", got, last - start);
}

static void handle(Stream& io, const String& command) {
  if (command == "ping") {
    io.println("pong");
  } else if (command == "info") {
    io.printf("%s rev %d, bt %s, up %lu ms\n", ESP.getChipModel(),
              ESP.getChipRevision(), bt.getBtAddressString().c_str(), millis());
  } else if (command.startsWith("burst ")) {
    burst(io, command.substring(6).toInt());
  } else if (command.startsWith("sink ")) {
    sink(io, command.substring(5).toInt());
  } else if (command == "forget") {
    bt.deleteAllBondedDevices();
    io.println("forgot all pairings");
  } else if (command == "bye") {
    io.println("bye");
    io.flush();
    delay(100);
    bt.disconnect();
  } else {
    io.print("echo: ");
    io.println(command);
  }
}

static void onBtEvent(esp_spp_cb_event_t event, esp_spp_cb_param_t* param) {
  if (event == ESP_SPP_SRV_OPEN_EVT) Serial.println("bt: connected");
  if (event == ESP_SPP_CLOSE_EVT) Serial.println("bt: disconnected");
}

void setup() {
  Serial.setRxBufferSize(4096);
  Serial.begin(115200);
  bt.register_callback(onBtEvent);
  bt.begin("SPP echo");
  delay(300);
  Serial.printf("bluetooth_serial_next echo ready, bt %s\n",
                bt.getBtAddressString().c_str());
}

void loop() {
  for (auto& channel : channels) {
    while (channel.io.available()) {
      const char c = channel.io.read();
      if (c == '\n' || c == '\r') {
        if (channel.line.length()) handle(channel.io, channel.line);
        channel.line = "";
      } else if (channel.line.length() < 256) {
        channel.line += c;
      }
    }
  }
}
