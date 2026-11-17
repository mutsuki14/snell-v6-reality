import com.esotericsoftware.kryo.io.ByteBufferInput;
import com.esotericsoftware.kryo.io.ByteBufferOutput;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Base64;
import java.util.zip.InflaterInputStream;

/** Check the exported packet with Exclave 0.17.68's actual Kryo 5.7.1 library. */
class ExclaveBackupCheck {
    public static void main(String[] args) throws Exception {
        String backup = Files.readString(Path.of(args[0])).strip();
        if (!backup.startsWith("config?")) throw new AssertionError("wrong backup type");
        byte[] bytes;
        try (var inflater = new InflaterInputStream(new ByteArrayInputStream(
                Base64.getDecoder().decode(backup.substring(7))))) {
            bytes = inflater.readAllBytes();
        }
        var input = new ByteBufferInput(bytes);
        if (input.readInt() != 1) throw new AssertionError("ConfigBean version");
        if (!input.readString().equals("v2ray")) throw new AssertionError("config type");
        String content = input.readString();
        if (!content.equals(Files.readString(Path.of(args[1])).strip()))
            throw new AssertionError("configuration differs from exported file");
        if (!input.readString().isEmpty()) throw new AssertionError("unexpected serverAddresses");
        if (input.readInt() != 2) throw new AssertionError("AbstractBean extra version");
        if (!input.readString().equals("Snell-v6-REALITY")) throw new AssertionError("name");
        if (input.readInt() != 0 || input.position() != bytes.length)
            throw new AssertionError("unexpected extraType or trailing data");
        var output = new ByteBufferOutput(4096, -1);
        output.writeInt(1);
        output.writeString("v2ray");
        output.writeString(content);
        output.writeString("");
        output.writeInt(2);
        output.writeString("Snell-v6-REALITY");
        output.writeInt(0);
        if (!Arrays.equals(bytes, output.toBytes())) throw new AssertionError("Kryo round trip");
        Files.writeString(Path.of(args[2]), content);
        System.out.println("PASS real Kryo decoding and byte-for-byte re-encoding of Exclave backup");
    }
}
