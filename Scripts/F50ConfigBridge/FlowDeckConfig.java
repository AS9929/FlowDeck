import java.io.File;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * F50 配置传输助手：不监听端口，只处理固定路径，命令及输出只含公钥、密文和摘要。
 * 由已认证的 UFI root 通道按需运行；会话密钥只保存在 root 私有目录中。
 */
public final class FlowDeckConfig {
    private static final Path ROOT = Paths.get("/data/local/flowdeck-config");
    private static final Path CONFIG = Paths.get("/data/clash/Proxy/config.yaml");
    private static final int LIMIT = 2 * 1024 * 1024;

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Exception error) {
            // 异常可能包含 YAML、密钥或路径细节，不能输出到 UFI 的调试日志。
            System.out.println("status=failed");
            System.exit(1);
        }
    }

    private static void run(String[] args) throws Exception {
        if (args.length < 2 || !args[1].matches("[a-f0-9]{32}")) {
            throw new IllegalArgumentException();
        }
        Path directory = ROOT.resolve(args[1]);
        if (args[0].equals("begin")) {
            if (args.length != 3 || Files.exists(directory)) {
                throw new IllegalArgumentException();
            }
            // 清理断线遗留的会话；不跟随链接，也不删除仍在使用的新会话。
            try (java.nio.file.DirectoryStream<Path> paths = Files.newDirectoryStream(ROOT)) {
                for (Path path : paths) {
                    if (path.getFileName().toString().matches("[a-f0-9]{32}")
                            && Files.getLastModifiedTime(path).toMillis() < System.currentTimeMillis() - 900000) {
                        cleanup(path);
                    }
                }
            }
            Files.createDirectory(directory, PosixFilePermissions.asFileAttribute(
                    PosixFilePermissions.fromString("rwx------")));
            KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            KeyPair pair = generator.generateKeyPair();
            KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
            agreement.init(pair.getPrivate());
            agreement.doPhase(KeyFactory.getInstance("EC").generatePublic(
                    new X509EncodedKeySpec(Base64.getDecoder().decode(args[2]))), true);
            byte[] key = MessageDigest.getInstance("SHA-256").digest(agreement.generateSecret());
            writePrivate(directory.resolve("key"), key);
            byte[] original = limitedRead(CONFIG, LIMIT);
            writePrivate(directory.resolve("baseline"), digest(original));
            writePrivate(directory.resolve("read"), encrypt(key, original, "read:" + args[1]));
            System.out.println("public=" + Base64.getEncoder().encodeToString(pair.getPublic().getEncoded()));
            System.out.println("status=ready");
            return;
        }
        if (args[0].equals("close")) {
            cleanup(directory);
            System.out.println("status=closed");
            return;
        }
        byte[] key = limitedRead(directory.resolve("key"), 32);
        if (args[0].equals("read")) {
            System.out.println("data=" + Base64.getEncoder().encodeToString(
                    limitedRead(directory.resolve("read"), LIMIT + 28)));
            return;
        }
        if (!args[0].equals("commit")) {
            throw new IllegalArgumentException();
        }
        // 所有提交共享排他锁，基准摘要在持锁后再次读取，拒绝会话期间的外部修改。
        Path operation = ROOT.resolve("operation");
        // 与核心升级共享目录锁。创建失败时不得删除其他任务持有的锁。
        try {
            Files.createDirectory(operation);
        } catch (java.nio.file.FileAlreadyExistsException busy) {
            System.out.println("status=busy");
            return;
        }
        try {
            if (!MessageDigest.isEqual(digest(limitedRead(CONFIG, LIMIT)),
                    limitedRead(directory.resolve("baseline"), 32))) {
                System.out.println("status=conflict");
                return;
            }
            byte[] packet = Base64.getDecoder().decode(limitedRead(directory.resolve("upload"), (LIMIT + 28) * 2));
            byte[] plaintext = decrypt(key, packet, "write:" + args[1]);
            if (plaintext.length == 0 || plaintext.length > LIMIT) {
                throw new IllegalArgumentException();
            }
            Path candidate = directory.resolve("candidate.yaml");
            writePrivate(candidate, plaintext);
            try {
                Process process = new ProcessBuilder("/data/clash/Proxy/Clash.Core", "-t", "-d",
                        "/data/clash/Proxy", "-f", candidate.toString())
                        .redirectErrorStream(true).redirectOutput(new File("/dev/null")).start();
                if (!process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) {
                    process.destroyForcibly();
                    System.out.println("status=validation-timeout");
                    return;
                }
                if (process.exitValue() != 0) {
                    System.out.println("status=invalid");
                    return;
                }
                Path backup = CONFIG.resolveSibling(".flowdeck-config.previous");
                writePrivate(backup, limitedRead(CONFIG, LIMIT));
                Files.move(candidate, CONFIG, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                System.out.println("sha256=" + hex(digest(limitedRead(CONFIG, LIMIT))));
                System.out.println("status=saved");
            } finally {
                Files.deleteIfExists(candidate);
            }
        } finally {
            Files.deleteIfExists(operation);
        }
    }

    static byte[] encrypt(byte[] key, byte[] data, String context) throws Exception {
        byte[] nonce = new byte[12];
        new SecureRandom().nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(context.getBytes("UTF-8"));
        byte[] encrypted = cipher.doFinal(data);
        byte[] packet = Arrays.copyOf(nonce, nonce.length + encrypted.length);
        System.arraycopy(encrypted, 0, packet, nonce.length, encrypted.length);
        return packet;
    }

    static byte[] decrypt(byte[] key, byte[] packet, String context) throws Exception {
        if (packet.length < 28) {
            throw new IllegalArgumentException();
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"),
                new GCMParameterSpec(128, Arrays.copyOf(packet, 12)));
        cipher.updateAAD(context.getBytes("UTF-8"));
        return cipher.doFinal(packet, 12, packet.length - 12);
    }

    private static byte[] limitedRead(Path path, int limit) throws Exception {
        if (Files.isSymbolicLink(path) || Files.size(path) > limit) {
            throw new IllegalArgumentException();
        }
        byte[] bytes = Files.readAllBytes(path);
        if (bytes.length > limit) {
            throw new IllegalArgumentException();
        }
        return bytes;
    }

    private static void writePrivate(Path path, byte[] data) throws Exception {
        Files.deleteIfExists(path);
        Files.createFile(path, PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
        try (RandomAccessFile file = new RandomAccessFile(path.toFile(), "rw")) {
            file.write(data);
            file.getFD().sync();
        }
    }

    private static byte[] digest(byte[] data) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(data);
    }

    private static String hex(byte[] data) {
        StringBuilder result = new StringBuilder();
        for (byte value : data) {
            result.append(String.format("%02x", value & 255));
        }
        return result.toString();
    }

    private static void cleanup(Path directory) throws Exception {
        if (!Files.exists(directory) || Files.isSymbolicLink(directory)) {
            return;
        }
        for (String name : new String[] {"key", "baseline", "read", "upload", "candidate.yaml"}) {
            Files.deleteIfExists(directory.resolve(name));
        }
        Files.deleteIfExists(directory);
    }
}
