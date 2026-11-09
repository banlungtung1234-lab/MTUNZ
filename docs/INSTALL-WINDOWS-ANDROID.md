# MTUNZ Unified Core 0.4.0-dev — hướng dẫn Windows 10/11 + Android

## Nền tảng hỗ trợ

- **Windows:** Windows 10/11, bản x64.
- **Android:** API 24 trở lên (Android 7.0+).
- **iPhone/iOS:** không nằm trong phạm vi phiên bản này.

## Điểm khác biệt của Unified Core

MTUNZ 0.4 tích hợp Core ghép nối ngay bên trong ứng dụng Windows và Android. Khi mở ứng dụng, Core tự khởi động; không cần chạy `MTUNZ-Signaling-Windows.exe`, không cần mở `start-server.bat`, không phải giữ một cửa sổ máy chủ riêng.

Core ưu tiên cổng TCP `8787`. Nếu cổng đó đang được chương trình khác sử dụng, MTUNZ tự chọn một cổng trống khác và hiển thị cổng thực tế trong lời mời kết nối.

## 1. Cài đặt ứng dụng

**Windows 10/11**

1. Giải nén toàn bộ gói Windows portable vào một thư mục.
2. Giữ nguyên thư mục `MTUNZ` cùng các DLL và thư mục `data` bên trong.
3. Nếu thiếu `VCRUNTIME140.dll`, `VCRUNTIME140_1.dll` hoặc `MSVCP140.dll`, cài Microsoft Visual C++ Redistributable x64 từ [trang tải chính thức](https://aka.ms/vc14/vc_redist.x64.exe).
4. Chạy `MTUNZ.exe`.
5. Khi Windows Firewall hỏi quyền truy cập mạng, chỉ cho phép MTUNZ trên mạng **Private** đáng tin cậy. Không cho phép trên Public network.

**Android**

1. Chép APK MTUNZ 0.4 vào điện thoại và cài đặt.
2. Mở MTUNZ và giữ ứng dụng hoạt động trong khi kết nối LAN.
3. Khi chia sẻ màn hình, chấp thuận hộp thoại MediaProjection của Android.
4. Để nhận thao tác điều khiển, chủ thiết bị phải tự bật MTUNZ Accessibility và xác nhận từng yêu cầu.

## 2. Tạo phòng và ghép nối

1. Kết nối Windows và Android vào cùng mạng Wi-Fi/LAN; hoặc chuẩn bị mạng Ethernet/USB tethering có định tuyến giữa hai thiết bị.
2. Mở MTUNZ trên cả hai thiết bị. Core tích hợp sẽ tự khởi động.
3. Trên thiết bị sẽ làm máy chủ phòng, chọn **Tạo phòng kết nối**.
4. Lời mời hiển thị mã phòng 8 ký tự, PIN 6 chữ số và các địa chỉ Core LAN của thiết bị tạo phòng.
5. Chọn địa chỉ thuộc mạng mà thiết bị còn lại có thể truy cập. Bấm nút sao chép bên cạnh địa chỉ đó.
6. Trên thiết bị còn lại, chọn **Nhập mã phòng**. Dán địa chỉ Core của thiết bị tạo phòng, sau đó nhập mã phòng và PIN.
7. Khi trạng thái chuyển sang đã kết nối, có thể chia sẻ màn hình, gửi tệp hoặc yêu cầu điều khiển.

**Không dùng `127.0.0.1` trên thiết bị tham gia.** Địa chỉ này luôn trỏ về chính thiết bị đang nhập địa chỉ. Hãy dùng địa chỉ LAN được hiển thị trong lời mời của thiết bị tạo phòng.

## 3. Chọn đúng địa chỉ mạng

- **Wi-Fi:** chọn địa chỉ IPv4 Wi-Fi khi hai thiết bị ở cùng mạng hoặc có thể định tuyến tới nhau.
- **Ethernet:** chọn IPv4 Ethernet trên PC nếu điện thoại và PC nằm trong cùng LAN.
- **USB tethering:** bật **Chia sẻ Internet qua USB / USB tethering** trên Android; trên Windows cần xuất hiện adapter RNDIS/USB. Chọn địa chỉ IPv4 của adapter mà Android có thể truy cập.
- Một dây USB đơn thuần không tạo ra giao thức truyền USB trực tiếp; MTUNZ dùng IP networking qua RNDIS/tethering.

Nếu không thấy địa chỉ LAN, vào **Cài đặt → WI-FI / ETHERNET / USB → Quét adapter mạng**. Nếu có nhiều địa chỉ, chọn đúng loại mạng đang dùng; không chọn adapter VPN hoặc adapter ảo không kết nối được với thiết bị kia.

## 4. Chia sẻ màn hình, điều khiển và truyền tệp

- **Chia sẻ màn hình:** bắt đầu trên thiết bị muốn được xem. Android yêu cầu xác nhận chia sẻ màn hình từ hệ thống.
- **Điều khiển Android:** bật MTUNZ trong Accessibility; thiết bị nhận phải chấp thuận yêu cầu trước khi có thao tác.
- **Truyền tệp:** mở mục **Tệp tin**, chọn thiết bị nhận, chọn tệp. Người nhận phải chấp nhận và tự chọn vị trí lưu.

Giới hạn hiện tại: tối đa 3 thiết bị/phòng, phòng hết hạn sau 15 phút, tệp tối đa 100 MB. Bên nhận hiện ghép toàn bộ tệp trong bộ nhớ trước khi lưu; chỉ cho phép một lượt nhận/lưu tại một thời điểm để hạn chế RAM.

## 5. Kết nối qua Internet khác mạng

Embedded Core là chế độ ghép nối trong LAN đáng tin cậy, không phải máy chủ Internet công cộng. Để kết nối qua hai mạng Internet khác nhau cần tự triển khai signaling HTTPS và TURN relay. Có thể tham khảo mẫu Linux VPS tại `deploy/README.md`; mẫu này cần VPS, domain/DNS, firewall và secrets riêng, không phải dịch vụ MTUNZ được host sẵn.

Không mở trực tiếp cổng HTTP Core nội bộ ra Internet. TURN-over-TLS và kiểm thử NAT thực tế qua nhiều nhà mạng vẫn là các hạng mục phát triển tiếp theo.

## 6. Chẩn đoán cơ bản

- Nếu Core không khởi động, mở **Cài đặt** và xem trạng thái Core; có thể bấm **Thử lại**.
- Nếu thiết bị khác không kết nối được, kiểm tra hai thiết bị có cùng mạng/định tuyến, dùng đúng IP LAN và đúng cổng hiện trong lời mời.
- Nếu Windows Firewall chặn kết nối, cho phép MTUNZ trên Private network.
- Nếu Core chạy nhưng kết nối WebRTC/video/file không thiết lập được, mạng có thể chặn P2P; khi đó cần TURN relay trong một deployment HTTPS bên ngoài.
- Khi thử nghiệm LAN, giữ MTUNZ đang mở trên cả hai thiết bị. Android có thể hạn chế hoạt động mạng khi ứng dụng bị đưa xuống nền.

## Các kiểm thử cần thực hiện trước khi coi là ổn định

CI analysis và build không thay thế kiểm thử phần cứng. Cần xác nhận trên Windows 10, Windows 11 và Android thực tế: tạo/join phòng, Wi-Fi hai chiều, Ethernet, USB tethering, chia sẻ màn hình, từ chối/cho phép điều khiển, truyền tệp hai chiều, từ chối/hủy tệp và khôi phục sau khi ngắt mạng.
