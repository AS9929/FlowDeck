import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import java.lang.reflect.Method;
import java.security.MessageDigest;

/** 检查 APK 的包名、版本和签名与已安装 UFI 的一致性。只读，不安装、不打印应用数据。 */
public final class FlowDeckPackage {
    private static final String PACKAGE = "com.minikano.f50_sms";

    public static void main(String[] args) {
        String stage = "arguments";
        try {
            if (args.length != 1 || !args[0].startsWith("/data/local/flowdeck-packages/")) {
                throw new IllegalArgumentException();
            }
            stage = "looper";
            if (android.os.Looper.myLooper() == null) {
                android.os.Looper.prepareMainLooper();
            }
            stage = "context";
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("systemMain").invoke(null);
            Method getContext = activityThread.getMethod("getSystemContext");
            Context context = (Context) getContext.invoke(thread);
            PackageManager manager = context.getPackageManager();
            stage = "installed";
            PackageInfo installed = manager.getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES | PackageManager.GET_SIGNATURES);
            stage = "candidate";
            PackageInfo candidate = manager.getPackageArchiveInfo(args[0], PackageManager.GET_SIGNING_CERTIFICATES | PackageManager.GET_SIGNATURES);
            if (candidate == null) {
                stage = "archive-empty";
                throw new IllegalArgumentException();
            }
            if (!PACKAGE.equals(candidate.packageName)) {
                stage = "package-name";
                throw new IllegalArgumentException();
            }
            stage = "signature";
            // 某些 Android 13 厂商框架只填充旧 signatures 字段；仍须有真实证书且逐字节一致。
            Signature[] original = installed.signingInfo != null
                    ? installed.signingInfo.getApkContentsSigners() : installed.signatures;
            Signature[] incoming = candidate.signingInfo != null
                    ? candidate.signingInfo.getApkContentsSigners() : candidate.signatures;
            if (original == null || incoming == null) {
                stage = "missing-signature";
                throw new IllegalArgumentException();
            }
            // 多签名/签名轮换必须单独适配，不能仅按显示包名放行。
            if (original.length != 1 || incoming.length != 1
                    || !MessageDigest.isEqual(original[0].toByteArray(), incoming[0].toByteArray())) {
                throw new IllegalArgumentException();
            }
            System.out.println("package=" + PACKAGE);
            System.out.println("version=" + candidate.versionName);
            System.out.println("code=" + candidate.getLongVersionCode());
            System.out.println("installed_code=" + installed.getLongVersionCode());
            System.out.println("status=verified");
        } catch (Exception error) {
            System.out.println("stage=" + stage);
            System.out.println("error=" + error.getClass().getSimpleName());
            if (error.getCause() != null) {
                System.out.println("cause=" + error.getCause().getClass().getSimpleName());
            }
            System.out.println("status=rejected");
        }
    }
}
