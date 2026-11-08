# MTUNZ 0.1.1-dev — cài đặt thử trong mạng Wi-Fi nội bộ

## Bạn cần gì?

- Một PC Windows 11.
- Một điện thoại Android (ví dụ Nubia Neo 2).
- Mã nguồn từ repository MTUNZ. Tải artifact `MTUNZ-Signaling-Windows` từ GitHub Actions để lấy máy chủ; APK và ứng dụng Windows cũng được tạo riêng từ workflow.
- Hai thiết bị cùng kết nối một mạng Wi-Fi.

## A. Chạy máy chủ ghép nối trên Windows

1. Tải artifact `MTUNZ-Signaling-Windows` từ lần chạy GitHub Actions thành công gần nhất rồi giải nén.
2. Đặt `MTUNZ-Signaling-Windows.exe` cùng thư mục với `start-server.bat`.
3. Chạy `start-server.bat`; tệp BAT đặt cổng `8787` rồi khởi chạy máy chủ.
4. Khi Windows Firewall hỏi, chỉ cho phép mạng **Private**.
5. Giữ cửa sổ máy chủ mở trong khi đang kết nối.
6. Mở Command Prompt, nhập `ipconfig`, tìm dòng IPv4 Address của card Wi-Fi (ví dụ `192.168.1.20`).

Máy chủ dùng cổng TCP `8787`. Không mở cổng này ra Internet trong bản thử nghiệm.

## B. Cài ứng dụng (sau khi có artifact build)

1. Trên Windows, giải nén toàn bộ `MTUNZ-Windows-x64.zip` vào một thư mục, ví dụ `C:\Apps\MTUNZ`.
2. Chạy `MTUNZ.exe` trong thư mục `Release`. Không tách riêng file EXE khỏi các DLL và thư mục `data` đi kèm.
3. Trên Android, mở `MTUNZ-Android.apk` đã build. Nếu Android chặn cài từ nguồn này, chỉ cấp quyền cài đặt cho ứng dụng quản lý tệp/trình duyệt mà bạn đang dùng và chỉ cài APK nhận từ nguồn MTUNZ của chính bạn.

**Lưu ý:** chỉ cài APK và Windows desktop ZIP sau khi GitHub Actions báo build thành công. Máy chủ ghép nối là artifact riêng, không phải ứng dụng Windows Desktop.

## C. Ghép nối

1. Vào **Cài đặt** trong MTUNZ trên cả hai thiết bị.
2. Nhập cùng địa chỉ máy chủ, ví dụ `http://192.168.1.20:8787`. Trên Android, không nhập `127.0.0.1`: địa chỉ loopback trỏ về chính điện thoại. Windows chạy máy chủ trên cùng PC có thể dùng `http://127.0.0.1:8787`.
3. Trên thiết bị thứ nhất, chọn **Tạo phòng kết nối**.
4. Trên thiết bị thứ hai, chọn **Nhập mã phòng**, điền mã phòng 8 ký tự và PIN 6 chữ số.
5. Trên thiết bị cần chia sẻ màn hình, chọn **Chia sẻ màn hình** và chấp thuận hộp thoại hệ thống Android nếu xuất hiện.
6. Muốn điều khiển Android, người đang cầm điện thoại phải tự bật MTUNZ trong Cài đặt Trợ năng và chấp thuận yêu cầu điều khiển.
7. Muốn điều khiển Windows, người dùng máy Windows phải chấp thuận yêu cầu trong MTUNZ. Bản phát triển hiện hỗ trợ chạm/nhấp và vuốt chuột; không điều khiển được màn hình khóa hoặc hộp thoại bảo mật UAC.

## D. Ngắt kết nối an toàn

Nhấn **Ngắt phiên** trong MTUNZ hoặc tắt chia sẻ màn hình. Có thể tắt MTUNZ Accessibility trong Android Settings bất cứ lúc nào. Đóng cửa sổ máy chủ khi không sử dụng.

## Lưu ý

Bản này dùng STUN để thử đường truyền trực tiếp. Nếu hai thiết bị khác mạng Wi-Fi, hoặc mạng chặn UDP/NAT traversal, video có thể không kết nối dù ghép nối đã thành công. Cần triển khai TURN qua TLS trước khi đưa ra Internet công cộng.
