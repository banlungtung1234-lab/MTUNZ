#include "mtunz_input_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <mutex>
#include <variant>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;
using flutter::StandardMethodCodec;

std::unique_ptr<MethodChannel<EncodableValue>> g_channel;
std::mutex g_input_mutex;

const EncodableValue* FindValue(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

double ReadNumber(const EncodableMap& map, const char* key, double fallback = 0.0) {
  const auto* value = FindValue(map, key);
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<double>(value)) return std::isfinite(*number) ? *number : fallback;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return static_cast<double>(*number);
  return fallback;
}

std::string ReadString(const EncodableMap& map, const char* key,
                       const std::string& fallback = "tap") {
  const auto* value = FindValue(map, key);
  if (value == nullptr) return fallback;
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  return fallback;
}

INPUT MouseInput(DWORD flags, double x, double y) {
  const double nx = std::clamp(x, 0.0, 1.0);
  const double ny = std::clamp(y, 0.0, 1.0);

  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = static_cast<LONG>(std::llround(nx * 65535.0));
  input.mi.dy = static_cast<LONG>(std::llround(ny * 65535.0));
  input.mi.mouseData = 0;
  input.mi.dwFlags = flags | MOUSEEVENTF_ABSOLUTE;
  input.mi.time = 0;
  input.mi.dwExtraInfo = 0;
  return input;
}

bool DispatchTap(double x, double y) {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  INPUT events[3]{};
  events[0] = MouseInput(MOUSEEVENTF_MOVE, x, y);
  events[1] = MouseInput(MOUSEEVENTF_LEFTDOWN, x, y);
  events[2] = MouseInput(MOUSEEVENTF_LEFTUP, x, y);
  const UINT sent = SendInput(3, events, sizeof(INPUT));
  if (sent < 3) {
    // Never leave the physical mouse button logically pressed after a
    // partially accepted input sequence.
    INPUT release = MouseInput(MOUSEEVENTF_LEFTUP, x, y);
    SendInput(1, &release, sizeof(INPUT));
    return false;
  }
  return true;
}

bool DispatchSwipe(double x, double y, double end_x, double end_y,
                   int duration_ms) {
  // Keep the Flutter UI thread responsive while the native input sequence runs.
  std::thread([x, y, end_x, end_y, duration_ms]() {
    std::lock_guard<std::mutex> lock(g_input_mutex);
    INPUT move = MouseInput(MOUSEEVENTF_MOVE, x, y);
    SendInput(1, &move, sizeof(INPUT));
    INPUT down = MouseInput(MOUSEEVENTF_LEFTDOWN, x, y);
    SendInput(1, &down, sizeof(INPUT));

    const int steps = 16;
    const int pause = std::clamp(duration_ms / steps, 5, 80);
    for (int step = 1; step <= steps; ++step) {
      const double t = static_cast<double>(step) / steps;
      INPUT motion = MouseInput(MOUSEEVENTF_MOVE,
                                x + (end_x - x) * t,
                                y + (end_y - y) * t);
      SendInput(1, &motion, sizeof(INPUT));
      Sleep(pause);
    }

    INPUT up = MouseInput(MOUSEEVENTF_LEFTUP, end_x, end_y);
    SendInput(1, &up, sizeof(INPUT));
  }).detach();
  return true;
}

void HandleMethodCall(const MethodCall<EncodableValue>& call,
                      std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() == "isAccessibilityEnabled") {
    result->Success(EncodableValue(true));
    return;
  }
  if (call.method_name() == "openAccessibilitySettings") {
    result->Success();
    return;
  }
  if (call.method_name() != "dispatchGesture") {
    result->NotImplemented();
    return;
  }

  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("INVALID_ARGS", "Gesture payload missing");
    return;
  }

  const std::string action = ReadString(*args, "action", "");
  if (action != "tap" && action != "swipe") {
    result->Error("INVALID_ACTION", "Only tap and swipe are supported.");
    return;
  }

  const double x = ReadNumber(*args, "x", -1.0);
  const double y = ReadNumber(*args, "y", -1.0);
  const double end_x = ReadNumber(*args, "endX", x);
  const double end_y = ReadNumber(*args, "endY", y);
  if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0 ||
      end_x < 0.0 || end_x > 1.0 || end_y < 0.0 || end_y > 1.0) {
    result->Error("INVALID_COORDINATES", "Gesture coordinates must be between 0 and 1.");
    return;
  }
  const int duration = static_cast<int>(std::clamp(
      ReadNumber(*args, "durationMs", 350.0), 80.0, 1500.0));

  const bool accepted = action == "swipe"
      ? DispatchSwipe(x, y, end_x, end_y, duration)
      : DispatchTap(x, y);
  result->Success(EncodableValue(accepted));
}

}  // namespace

void RegisterMtunzInput(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "mtunz/native_control", &StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleMethodCall);
}
