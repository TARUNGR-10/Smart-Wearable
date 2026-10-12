#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <TinyGPSPlus.h>
#include <HardwareSerial.h>
#include <time.h>

// Fill these in locally. Do NOT share passwords.
const char* WIFI_SSID = "Yashas";
const char* WIFI_PASSWORD = "Yashas@18";
const char* FIREBASE_API_KEY = "AIzaSyBo6AOobDbOlfXaJgKq4B550CLVN3YzOWU";
const char* FIREBASE_PROJECT_ID = "smart-wearable-system";
const char* WOMAN_EMAIL = "yashas18y@gmail.com";
const char* WOMAN_PASSWORD = "Yashas@9999";
const char* WOMAN_UID = "rLvkqzDVflV7mSfkehMziwX0bZC3";



// Wiring: GPS TX->GPIO16, GPS RX->GPIO17; button GPIO32->GND;
// green LED GPIO14 through resistor to GND; red LED GPIO33 through resistor to GND.
TinyGPSPlus gps;
HardwareSerial GPS(2);
const int GPS_RX = 16, GPS_TX = 17;
const int SOS_BUTTON = 32, GREEN_LED = 14, RED_LED = 33;

String idToken, refreshToken, activeAlertId;
unsigned long tokenExpiresAt = 0, lastPollAt = 0, lastLocationUpdateAt = 0;
bool alertPending = false;
bool waitingForButtonReleaseAfterAck = false;
unsigned long acknowledgedAt = 0;
unsigned long lastRedBlinkAt = 0;
bool redLedState = false;
const unsigned long RED_BLINK_INTERVAL_MS = 10000;
const unsigned long RED_LED_ON_MS = 500;
const unsigned long ACK_POLL_MS = 5000;
const unsigned long LOCATION_UPDATE_INTERVAL_MS = 10000; // update location every 2 minutes

void readGPS();
void waitForButtonRelease();
bool countdown();
bool waitAndCheckCancel(unsigned long duration);
bool connectWiFi();
bool signInToFirebase();
bool refreshFirebaseToken();
bool ensureValidToken();
bool getFreshGPS(double &lat, double &lng);
bool createFirestoreAlert(double lat, double lng);
bool pollParentAcknowledgement();
bool updateFirestoreLocation(double lat, double lng);
bool syncClock();

void setup() {
  Serial.begin(115200);
  delay(1000);
  pinMode(SOS_BUTTON, INPUT_PULLUP);
  pinMode(GREEN_LED, OUTPUT);
  pinMode(RED_LED, OUTPUT);
  digitalWrite(GREEN_LED, LOW);
  digitalWrite(RED_LED, LOW);
  GPS.begin(9600, SERIAL_8N1, GPS_RX, GPS_TX);

  Serial.println("\nSMART SAFETY SYSTEM - FIREBASE ONLINE MODE");
  Serial.println("SIM800L and SMS are disabled.");
  if (connectWiFi() && signInToFirebase()) {
    Serial.println("Firebase sign-in successful.");
  } else {
    Serial.println("Startup authentication/network failed. Check messages above.");
    digitalWrite(RED_LED, HIGH);
  }
  Serial.println("Waiting for GPS fix; keep antenna outdoors.");
  Serial.println("SYSTEM READY: press SOS once; press again during countdown to cancel.");
}

11
    } else if (millis() - lastRedBlinkAt >= RED_BLINK_INTERVAL_MS) {
      // Start one brief blink every 7 seconds while awaiting acknowledgement.
      lastRedBlinkAt = millis();
      redLedState = true;
      digitalWrite(RED_LED, HIGH);
    }
    // Update the same active Firebase alert with the latest GPS position every 2 minutes.
    // This runs only while the alert is pending and Wi-Fi is available.
    if (millis() - lastLocationUpdateAt >= LOCATION_UPDATE_INTERVAL_MS) {
      lastLocationUpdateAt = millis();
      double latestLat, latestLng;
      if (getFreshGPS(latestLat, latestLng)) {
        if (updateFirestoreLocation(latestLat, latestLng)) {
          Serial.print("Alert location updated. Latitude: ");
          Serial.print(latestLat, 6);
          Serial.print(", Longitude: ");
          Serial.println(latestLng, 6);
        } else {
          Serial.println("Location update failed; will try again in 2 minutes.");
        }
      } else {
        Serial.println("Location update skipped: no fresh GPS fix.");
      }
    }

    if (millis() - lastPollAt >= ACK_POLL_MS) {
      lastPollAt = millis();
      if (pollParentAcknowledgement()) {
        alertPending = false;
        redLedState = false;
        digitalWrite(RED_LED, LOW);
        digitalWrite(GREEN_LED, LOW);
        Serial.println("PARENT ACKNOWLEDGED ALERT. GREEN LED BLINKS TWICE.");
        for (int i = 0; i < 2; i++) {
          digitalWrite(GREEN_LED, HIGH);
          delay(300);
          digitalWrite(GREEN_LED, LOW);
          delay(300);
        }
        Serial.println("System will re-arm automatically after you release the SOS button."); 
        acknowledgedAt = millis();
        waitingForButtonReleaseAfterAck = true;
      }
    }
    delay(10);
    return;
  }

  // After acknowledgement, wait for the button to be released, then re-arm automatically.
  if (waitingForButtonReleaseAfterAck) {
    if (digitalRead(SOS_BUTTON) != LOW) {
      waitingForButtonReleaseAfterAck = false;
      activeAlertId = "";
      redLedState = false;
      digitalWrite(RED_LED, LOW);
      digitalWrite(GREEN_LED, LOW);
      Serial.println("SYSTEM READY FOR NEXT SOS.");
    }
    delay(10);
    return;
  }

  if (digitalRead(SOS_BUTTON) != LOW) { delay(10); return; }
  delay(50);
  if (digitalRead(SOS_BUTTON) != LOW) return;

  Serial.println("\nSOS BUTTON PRESSED.");
digitalWrite(GREEN_LED, LOW);
digitalWrite(RED_LED, LOW);

Serial.println("Release the button to start countdown.");
waitForButtonRelease();

Serial.println("Starting countdown now...");
  if (countdown()) {
    Serial.println("SOS CANCELLED. No alert created.");
    digitalWrite(GREEN_LED, LOW);
    digitalWrite(RED_LED, LOW);
    return;
  }

  double lat, lng;
  Serial.println("Countdown finished. Reading GPS...");
  if (!getFreshGPS(lat, lng)) {
    Serial.println("GPS FIX UNAVAILABLE. No alert created.");
    digitalWrite(RED_LED, HIGH);
    return;
  }
  Serial.print("Latitude: "); Serial.println(lat, 6);
  Serial.print("Longitude: "); Serial.println(lng, 6);

  if (!ensureValidToken()) {
    Serial.println("Firebase authentication/network unavailable. No alert created.");
    digitalWrite(RED_LED, HIGH);
    return;
  }
  if (createFirestoreAlert(lat, lng)) {
    alertPending = true;
    lastPollAt = 0;
    lastLocationUpdateAt = millis(); // first location refresh occurs 2 minutes after alert creation
    lastRedBlinkAt = millis();
    redLedState = false;
    digitalWrite(RED_LED, LOW);
    Serial.print("Firestore alert created. Document ID: ");
    Serial.println(activeAlertId);
    Serial.println("Waiting for parent dashboard acknowledgement...");
  } else {
    Serial.println("Firestore alert creation failed; see HTTP error above.");
    digitalWrite(RED_LED, HIGH);
  }
}

bool connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return true;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to Wi-Fi");
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    readGPS();
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Wi-Fi failed. Check SSID/password and use a 2.4 GHz hotspot.");
    return false;
  }
  Serial.print("Wi-Fi connected. IP: "); Serial.println(WiFi.localIP());
  syncClock();
  return true;
}

bool syncClock() {
  // Try multiple NTP servers and allow up to 20 seconds for a valid UTC time.
  configTime(0, 0, "pool.ntp.org", "time.google.com", "time.cloudflare.com");
  unsigned long start = millis();
  while (time(nullptr) < 1700000000 && millis() - start < 20000) {
    readGPS();
    delay(200);
  }
  if (time(nullptr) < 1700000000) {
    Serial.println("NTP time sync failed; will retry before creating/updating Firebase data.");
    return false;
  }
  Serial.println("ESP32 clock synchronized.");
  return true;
}

bool signInToFirebase() {
  if (!connectWiFi()) return false;
  WiFiClientSecure client;
  client.setInsecure(); // Prototype only; use TLS certificate validation in production.
  HTTPClient http;
  String url = String("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=") + FIREBASE_API_KEY;
  JsonDocument req;
  req["email"] = WOMAN_EMAIL;
  req["password"] = WOMAN_PASSWORD;
  req["returnSecureToken"] = true;
  String body;
  serializeJson(req, body);
  Serial.println("Signing in to Firebase Authentication...");
  if (!http.begin(client, url)) return false;
  http.addHeader("Content-Type", "application/json");
  int status = http.POST(body);
  String response = http.getString();
  http.end();
  if (status != 200) {
    Serial.print("Firebase sign-in HTTP "); Serial.println(status);
    Serial.println(response);
    return false;
  }
  JsonDocument res;
  if (deserializeJson(res, response)) { Serial.println("Invalid Firebase auth response."); return false; }
  String uid = res["localId"] | "";
  idToken = res["idToken"] | "";
  refreshToken = res["refreshToken"] | "";
  const char* exp = res["expiresIn"] | "3600";
  unsigned long seconds = String(exp).toInt();
  if (uid != String(WOMAN_UID)) {
    Serial.println("UID MISMATCH. Check WOMAN_UID against Firebase Authentication.");
    Serial.print("Authenticated UID: "); Serial.println(uid);
    idToken = ""; refreshToken = "";
    return false;
  }
  if (!idToken.length() || !refreshToken.length()) {
    Serial.println("Firebase response did not contain tokens."); return false;
  }
  tokenExpiresAt = millis() + (seconds > 60 ? seconds - 60 : 30) * 1000UL;
  Serial.println("Firebase UID verified.");
  return true;
}

bool refreshFirebaseToken() {
  if (!refreshToken.length()) return signInToFirebase();
  if (!connectWiFi()) return false;
  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  String url = String("https://securetoken.googleapis.com/v1/token?key=") + FIREBASE_API_KEY;
  String body = "grant_type=refresh_token&refresh_token=" + refreshToken;
  if (!http.begin(client, url)) return false;
  http.addHeader("Content-Type", "application/x-www-form-urlencoded");
  int status = http.POST(body);
  String response = http.getString();
  http.end();
  if (status != 200) {
    Serial.print("Token refresh HTTP "); Serial.println(status);
    Serial.println(response);
    return false;
  }
  JsonDocument res;
  if (deserializeJson(res, response)) return false;
  idToken = res["id_token"] | "";
  String newRefresh = res["refresh_token"] | "";
  if (newRefresh.length()) refreshToken = newRefresh;
  const char* exp = res["expires_in"] | "3600";
  unsigned long seconds = String(exp).toInt();
  tokenExpiresAt = millis() + (seconds > 60 ? seconds - 60 : 30) * 1000UL;
  return idToken.length() > 0;
}

bool ensureValidToken() {
  if (WiFi.status() != WL_CONNECTED && !connectWiFi()) return false;
  if (!idToken.length()) return signInToFirebase();
  if ((long)(millis() - tokenExpiresAt) >= 0) {
    Serial.println("Refreshing Firebase token...");
    return refreshFirebaseToken();
  }
  return true;
}

void readGPS() {
  while (GPS.available()) gps.encode(GPS.read());
}

bool getFreshGPS(double &lat, double &lng) {
  unsigned long start = millis();
  while ((!gps.location.isValid() || gps.location.age() > 10000) && millis() - start < 20000) {
    readGPS();
    delay(10);
  }
  if (!gps.location.isValid() || gps.location.age() > 10000) {
    Serial.println("No fresh GPS fix. Move antenna outdoors.");
    Serial.print("Satellites: ");
    if (gps.satellites.isValid()) Serial.println(gps.satellites.value());
    else Serial.println("not available");
    return false;
  }
  lat = gps.location.lat();
  lng = gps.location.lng();
  return true;
}

void waitForButtonRelease() {
  while (digitalRead(SOS_BUTTON) == LOW) { readGPS(); delay(10); }
  delay(100);
}

bool countdown() {
  Serial.println("SOS COUNTDOWN STARTED. Press button again to cancel.");
  for (int s = 5; s >= 1; --s) {
    Serial.print("Time remaining: "); Serial.println(s);
    if (waitAndCheckCancel(1000)) return true;
  }
  return false;
}

bool waitAndCheckCancel(unsigned long duration) {
  unsigned long start = millis();
  while (millis() - start < duration) {
    readGPS();
    if (digitalRead(SOS_BUTTON) == LOW) {
      delay(50);
      if (digitalRead(SOS_BUTTON) == LOW) {
        Serial.println("SOS CANCELLED.");
        waitForButtonRelease();
        return true;
      }
    }
    delay(10);
  }
  return false;
}

bool createFirestoreAlert(double lat, double lng) {
  if (!ensureValidToken()) return false;
  if (time(nullptr) < 1700000000 && !syncClock()) {
    Serial.println("Clock not synchronized; createdAt timestamp unavailable.");
    return false;
  }
  time_t now = time(nullptr);
  if (now < 1700000000) {
    Serial.println("Clock not synchronized; createdAt timestamp unavailable.");
    return false;
  }
  struct tm utc;
  gmtime_r(&now, &utc);
  char timestamp[30];
  strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%SZ", &utc);

  JsonDocument doc;
  JsonObject f = doc["fields"].to<JsonObject>();
  f["userId"]["stringValue"] = WOMAN_UID;
  f["latitude"]["doubleValue"] = lat;
  f["longitude"]["doubleValue"] = lng;
  f["message"]["stringValue"] = "SOS Emergency Alert";
  f["details"]["stringValue"] = "Emergency assistance required.";
  f["status"]["stringValue"] = "new";
  f["acknowledged"]["booleanValue"] = false;
  f["createdAt"]["timestampValue"] = timestamp;
  String body;
  serializeJson(doc, body);

  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  String url = String("https://firestore.googleapis.com/v1/projects/") + FIREBASE_PROJECT_ID +
               "/databases/(default)/documents/alerts";
  if (!http.begin(client, url)) return false;
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", "Bearer " + idToken);
  Serial.println("Creating Firestore alert...");
  int status = http.POST(body);
  String response = http.getString();
  http.end();
  if (status != 200) {
    Serial.print("Firestore create HTTP "); Serial.println(status);
    Serial.println(response);
    return false;
  }
  JsonDocument res;
  if (deserializeJson(res, response)) { Serial.println(response); return false; }
  String name = res["name"] | "";
  int slash = name.lastIndexOf('/');
  if (slash < 0 || slash == (int)name.length() - 1) {
    Serial.println("Firestore response missing document ID."); return false;
  }
  activeAlertId = name.substring(slash + 1);
  return true;
}

bool updateFirestoreLocation(double lat, double lng) {
  if (!activeAlertId.length() || !ensureValidToken()) return false;
  if (WiFi.status() != WL_CONNECTED && !connectWiFi()) return false;

  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["latitude"]["doubleValue"] = lat;
  fields["longitude"]["doubleValue"] = lng;
  String body;
  serializeJson(doc, body);

  WiFiClientSecure client;
  client.setInsecure(); // Prototype only; use TLS certificate validation in production.
  HTTPClient http;
  String url = String("https://firestore.googleapis.com/v1/projects/") + FIREBASE_PROJECT_ID +
               "/databases/(default)/documents/alerts/" + activeAlertId +
               "?updateMask.fieldPaths=latitude&updateMask.fieldPaths=longitude";
  if (!http.begin(client, url)) return false;
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", "Bearer " + idToken);
  Serial.println("Updating active alert GPS location...");
  int status = http.PATCH(body);
  String response = http.getString();
  http.end();
  if (status != 200) {
    Serial.print("Firestore location update HTTP "); Serial.println(status);
    Serial.println(response);
    return false;
  }
  return true;
}

bool pollParentAcknowledgement() {
  if (!ensureValidToken()) {
    Serial.println("Cannot check acknowledgement: network/auth unavailable.");
    return false;
  }
  WiFiClientSecure client;
  client.setInsecure();
  HTTPClient http;
  String url = String("https://firestore.googleapis.com/v1/projects/") + FIREBASE_PROJECT_ID +
               "/databases/(default)/documents/alerts/" + activeAlertId;
  if (!http.begin(client, url)) return false;
  http.addHeader("Authorization", "Bearer " + idToken);
  int status = http.GET();
  String response = http.getString();
  http.end();
  if (status != 200) {
    Serial.print("Acknowledgement check HTTP "); Serial.println(status);
    Serial.println(response);
    return false;
  }
  JsonDocument res;
  if (deserializeJson(res, response)) return false;
  String state = res["fields"]["status"]["stringValue"] | "";
  bool acknowledged = res["fields"]["acknowledged"]["booleanValue"] | false;
  if (state == "acknowledged" || acknowledged) return true;
  Serial.println("Alert pending; waiting for parent acknowledgement.");
  return false;
}
