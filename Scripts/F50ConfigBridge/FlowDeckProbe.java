import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.security.SecureRandom;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;

/** 有界 UDP DNS 探测。仅查询固定公共域名，不发送订阅、短信或设备身份。 */
public final class FlowDeckProbe {
    /** 比对原问题并逐条检查回答边界，不能只凭 ANCOUNT 就认为解析成功。 */
    static boolean validResponse(byte[] bytes, int length, int id, byte[] query) {
        if (length < query.length || word(bytes, 0) != id || (bytes[2] & 0xF8) != 0x80
                || (bytes[2] & 2) != 0 || (bytes[3] & 15) != 0 || word(bytes, 4) != 1) {
            return false;
        }
        for (int index = 12; index < query.length; index++) {
            if (bytes[index] != query[index]) {
                return false;
            }
        }
        int cursor = query.length;
        boolean addressFound = false;
        int answers = word(bytes, 6);
        for (int answer = 0; answer < answers; answer++) {
            cursor = skipName(bytes, length, cursor);
            if (cursor < 0 || cursor + 10 > length) {
                return false;
            }
            int type = word(bytes, cursor);
            int family = word(bytes, cursor + 2);
            int size = word(bytes, cursor + 8);
            cursor += 10;
            if (cursor + size > length) {
                return false;
            }
            addressFound |= type == 1 && family == 1 && size == 4;
            cursor += size;
        }
        return addressFound;
    }

    private static int word(byte[] bytes, int offset) {
        return (bytes[offset] & 255) * 256 + (bytes[offset + 1] & 255);
    }

    private static int skipName(byte[] bytes, int length, int cursor) {
        while (cursor < length) {
            int count = bytes[cursor++] & 255;
            if (count == 0) {
                return cursor;
            }
            if ((count & 0xC0) == 0xC0) {
                if (cursor >= length || ((count & 63) * 256 + (bytes[cursor] & 255)) >= cursor - 1) {
                    return -1;
                }
                return cursor + 1;
            }
            if (count > 63 || cursor + count > length) {
                return -1;
            }
            cursor += count;
        }
        return -1;
    }

    public static void main(String[] args) {
        try {
            if (args.length != 1 || !args[0].matches("[0-9.]{7,15}")) {
                throw new IllegalArgumentException();
            }
            int id = new SecureRandom().nextInt(65536);
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            DataOutputStream output = new DataOutputStream(buffer);
            output.writeShort(id);
            output.writeShort(0x0100);
            output.writeShort(1);
            output.writeShort(0);
            output.writeShort(0);
            output.writeShort(0);
            for (String label : new String[] {"www", "example", "com"}) {
                output.writeByte(label.length());
                output.writeBytes(label);
            }
            output.writeByte(0);
            output.writeShort(1);
            output.writeShort(1);
            InetAddress server = InetAddress.getByName(args[0]);
            try (DatagramSocket socket = new DatagramSocket()) {
                socket.setSoTimeout(3000);
                socket.connect(server, 53);
                byte[] query = buffer.toByteArray();
                socket.send(new DatagramPacket(query, query.length));
                byte[] result = new byte[4096];
                DatagramPacket packet = new DatagramPacket(result, result.length);
                socket.receive(packet);
                boolean matched = validResponse(result, packet.getLength(), id, query);
                System.out.println(matched ? "probe=passed" : "probe=invalid-response");
            }
        } catch (java.net.SocketTimeoutException timeout) {
            System.out.println("probe=timeout");
        } catch (Exception error) {
            System.out.println("probe=unavailable");
        }
    }
}
