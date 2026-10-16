package io.github.voidnullvalue.snusnuroot.persistence;

final class FirmwareGuard {
    private FirmwareGuard() {}

    static boolean matches(String expected, String device, String build,
            String incremental, String fingerprint) {
        if (expected == null || device == null || build == null
                || incremental == null || fingerprint == null) {
            return false;
        }
        String[] fields = expected.split("\\|", -1);
        if (fields.length != 3 || fields[0].isEmpty() || fields[1].isEmpty()
                || fields[2].isEmpty()) {
            return false;
        }
        if (!fields[0].equals(device) || !fields[1].equals(build)
                || !fields[2].equals(incremental)) {
            return false;
        }
        String prefix = "Amazon/" + device + "/" + device + ":";
        return fingerprint.startsWith(prefix)
                && fingerprint.contains("/" + build + "/");
    }
}
