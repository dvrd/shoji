// Map verified exact-cache stubs to external functions in an analysis copy only.
// @category Shoji
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.CodeUnit;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.ExternalLocation;
import ghidra.program.model.symbol.SourceType;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public class MapCacheStubs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String expected = "b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673";
        if (!expected.equals(currentProgram.getExecutableSHA256())) {
            throw new IllegalStateException("unsupported program identity");
        }
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: MapCacheStubs.java manifest.tsv");
        }
        List<String> rows = Files.readAllLines(Path.of(args[0]));
        if (rows.isEmpty() || rows.size() > 256) {
            throw new IllegalArgumentException("invalid manifest row count");
        }
        // Validate the complete manifest before adding analysis memory.
        for (String row : rows) {
            String[] fields = row.split("\t", -1);
            if (fields.length != 6 || !fields[4].matches("[0-9a-f]{32}")) {
                throw new IllegalArgumentException("invalid manifest row");
            }
            Address entry = toAddr(fields[0]);
            if (currentProgram.getMemory().intersects(entry, entry.add(15))) {
                throw new IllegalStateException("refusing to overwrite mapped memory: " + entry);
            }
        }
        int count = 0;
        for (String row : rows) {
            monitor.checkCancelled();
            String[] fields = row.split("\t", -1);
            Address entry = toAddr(fields[0]);
            byte[] bytes = new byte[16];
            for (int i = 0; i < bytes.length; i++) {
                bytes[i] = (byte) Integer.parseInt(fields[4].substring(i * 2, i * 2 + 2), 16);
            }
            MemoryBlock block = currentProgram.getMemory().createInitializedBlock(
                "cache_stub_" + entry, entry, new ByteArrayInputStream(bytes), 16, monitor, false);
            block.setRead(true);
            block.setWrite(false);
            block.setExecute(true);
            block.setComment("Exact guest-cache bytes; analysis-only reconstruction, not image contents");
            disassemble(entry);
            ExternalLocation external = currentProgram.getExternalManager().addExtFunction(
                fields[2], fields[3], toAddr(fields[1]), SourceType.USER_DEFINED);
            Function function = currentProgram.getFunctionManager().createFunction(
                "cache_stub_" + entry, entry, new AddressSet(entry, entry.add(15)), SourceType.USER_DEFINED);
            if (function == null || external.getFunction() == null) {
                throw new IllegalStateException("could not create function mapping for " + entry);
            }
            function.setThunkedFunction(external.getFunction());
            currentProgram.getListing().setComment(entry, CodeUnit.PLATE_COMMENT,
                "Verified guest cache: " + fields[2] + " " + fields[3] + " @ " + fields[1] +
                "; " + fields[5] + "; external signature not recovered by this mapping");
            count++;
        }
        println("MAPPED_CACHE_STUBS=" + count);
    }
}
