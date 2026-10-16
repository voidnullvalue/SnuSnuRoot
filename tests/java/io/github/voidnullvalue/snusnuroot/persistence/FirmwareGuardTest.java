package io.github.voidnullvalue.snusnuroot.persistence;

public final class FirmwareGuardTest {
    private static void expect(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        String fingerprint =
                "Amazon/trona/trona:9/PS7331.4460N/device:user/amz-p,release-keys";
        expect(FirmwareGuard.matches("trona|PS7331.4460N|0031575862404",
                "trona", "PS7331.4460N", "0031575862404", fingerprint),
                "exact pinned firmware rejected");
        expect(!FirmwareGuard.matches(null, "trona", "PS7331.4460N",
                "0031575862404", fingerprint), "missing pin accepted");
        expect(!FirmwareGuard.matches("trona|PS7331.4460N|0031575862404",
                "trona", "PS7331.4460N", "0031575862405", fingerprint),
                "changed incremental accepted");
        expect(!FirmwareGuard.matches("trona|PS7331.4460N|0031575862404",
                "trona", "PS7329.3842N", "0031575862404", fingerprint),
                "changed build accepted");
        expect(!FirmwareGuard.matches("trona|PS7331.4460N|0031575862404",
                "trona", "PS7331.4460N", "0031575862404",
                "Amazon/other/other:9/PS7331.4460N/device:user/release-keys"),
                "inconsistent fingerprint accepted");
        System.out.println("PASS: autonomous firmware identity guard");
    }
}
