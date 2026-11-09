# MTUNZ 0.3.1-dev — hướng dẫn cài Windows 10/11 + Android

## Nền tảng hỗ trợ

- **Windows:** Windows 10/11, bản x64.
- **Android:** API 24 trở lên (Android 7.0+). APK được build cho arm64-v8a, armeabi-v7a và x86_64.
- **iPhone/iOS:** không nằm trong phạm vi của phiên bản này.

## Gói cài đặt

Gói thử nghiệm gồm ứng dụng Android APK, bộ ứng dụng Windows portable, MTUNZ Signaling Server và tệp khởi chạy máy chủ. Có thể dùng chung Wi-Fi, router Ethernet hoặc Android USB tethering; điều kiện là hai thiết bị phải truy cập được địa chỉ IP của máy chạy signaling server.

## 1. Giải nén gói

Giải nén toàn bộ `MTUNZ-0.3.1-dev-Install-Pack.zip` vào một thư mục trên PC. Giữ nguyên cấu trúc thư mục bên trong.

## 2. Chạy máy chủ trên Windows

1. Mở thư mục `Server`.
2. Nhấp đúp `start-server.bat`.
3. Khi Windows Firewall hỏi, chỉ cho phép kết nối trên mạng **Private**.
4. Giữ cửa sổ máy chủ mở trong khi hai thiết bị sử dụng MTUNZ.
5. Mở MTUNZ trên Windows → **Cài đặt** → mục **WI-FI / ETHERNET / USB** → **Quét adapter mạng**. Chọn IPv4 thuộc adapter Ethernet, Wi-Fi hoặc RNDIS/USB mà điện thoại có thể truy cập. Nếu chưa dùng được màn hình quét, chạy `ipconfig` và xem IPv4 của đúng adapter. Ví dụ: `192.168.1.20`.

Máy chủ dùng cổng TCP `8787`. Đây là cấu hình thử nghiệm mạng nội bộ; không mở cổng này trực tiếp ra Internet.

## 3. Cài ứng dụng

**Windows:** mở thư mục `Windows/MTUNZ` trong gói, sau đó chạy `MTUNZ.exe`. Không di chuyển riêng file EXE ra khỏi thư mục vì ứng dụng cần các DLL và thư mục `data` đi kèm.

**Android:** chép `Android/MTUNZ-Android-0.3.1-dev.apk` sang điện thoại và mở để cài đặt. Chỉ cấp quyền cài ứng dụng không rõ nguồn cho trình quản lý tệp/trình duyệt mà bạn đang dùng, sau đó có thể tắt quyền này lại.

## 4. Ghép nối hai thiết bị

1. Mở MTUNZ trên Windows và Android.
2. Trên Windows, chọn adapter IPv4 trong mục mạng có dây ở Cài đặt. Trên Android, nhập cùng địa chỉ máy chủ, ví dụ `http://192.168.1.20:8787`. Nếu Windows dùng USB tethering, bật **USB tethering/Chia sẻ Internet qua USB** trên điện thoại trước khi quét.
3. Trên thiết bị thứ nhất, chọn **Tạo phòng kết nối**.
4. Trên thiết bị thứ hai, chọn **Nhập mã phòng**, điền mã phòng 8 ký tự và PIN 6 chữ số.
5. Khi thấy trạng thái thiết bị đã kết nối, hai thiết bị có thể bắt đầu chia sẻ màn hình hoặc truyền tệp.

Trên Android, không nhập `127.0.0.1`: địa chỉ đó trỏ về chính điện thoại. Windows chạy máy chủ trên cùng PC mới có thể dùng `http://127.0.0.1:8787`.

## 5. Truyền tệp

1. Mở mục **Tệp tin** trong MTUNZ.
2. Chọn thiết bị nhận trong danh sách.
3. Bấm **Chọn tệp và gửi**, rồi chọn một tệp trên thiết bị gửi.
4. Trên thiết bị nhận, đọc tên và dung lượng tệp trong hộp thoại rồi chọn **Chấp nhận tệp** hoặc **Từ chối**.
5. Nếu chấp nhận, chọn vị trí lưu trong hộp thoại hệ thống.
6. Hai bên có thể xem tiến trình truyền và hủy khi đang truyền.

Giới hạn hiện tại là **100 MB cho mỗi tệp**. Bên nhận ghép toàn bộ tệp trong bộ nhớ trước khi mở hộp thoại lưu; MTUNZ chỉ nhận/lưu một tệp tại một thời điểm để hạn chế tăng RAM. Gói truyền dùng chunk 60 KB và hàng đợi gửi có kiểm soát 4/2 MB; tốc độ thực tế vẫn phụ thuộc mạng, CPU và thiết bị nhận.

## 6. Lưu ý khi kiểm thử

- CI chạy Flutter analyze/tests, Android APK build, Windows x64 build trên hai runner Windows, Go race tests/vet và Windows signaling cross-build. Đây là kiểm tra build trên runner, không thay thế chạy thử trực tiếp trên máy Windows 10 và Windows 11.
- CI không thay thế kiểm thử thực tế. Cần thử gửi tệp nhỏ theo cả hai chiều Windows → Android và Android → Windows, thử từ chối, hủy, hủy chọn nơi lưu và ngắt Wi-Fi giữa chừng.
- Kết nối WebRTC trực tiếp có thể không thành công trên một số mạng NAT/nhà mạng. MTUNZ thử nhiều STUN server và tự khởi động lại ICE có giới hạn. Để đi qua NAT khó, cần cấu hình coturn và credential TURN ngắn hạn trên máy chủ.
- Signaling server hiện dùng HTTP cho thử nghiệm LAN. Không đưa máy chủ này trực tiếp lên Internet công cộng.
- Tùy chọn TURN: đặt `MTUNZ_TURN_URLS` (ví dụ `turn:turn.example.net:3478?transport=udp,turns:turn.example.net:5349?transport=tcp`), `MTUNZ_TURN_SHARED_SECRET` (ít nhất 32 ký tự ngẫu nhiên, đồng bộ với coturn) và tùy chọn `MTUNZ_TURN_CREDENTIAL_TTL_SECONDS` (60–3600 giây). Khi bật TURN, phải đặt signaling server sau HTTPS trước khi dùng qua Internet vì thông tin TURN được gửi trong phản hồi ghép nối.
- Khi xong, chọn **Ngắt phiên** và đóng cửa sổ signaling server.

## Thành phần trong gói

- `Android/MTUNZ-Android-0.3.1-dev.apk` — APK đa kiến trúc, gồm arm64-v8a, armeabi-v7a và x86_64.
- `Windows/MTUNZ/` — ứng dụng Windows portable và các thư viện đi kèm.
- `Server/MTUNZ-Signaling-Windows.exe` — máy chủ ghép nối Windows.
- `Server/start-server.bat` — tệp chạy máy chủ trên cổng 8787.
- `SHA256SUMS.txt` — mã SHA-256 để kiểm tra tệp.
