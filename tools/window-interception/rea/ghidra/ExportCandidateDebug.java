// Capture Ghidra's standalone-decompiler save state for one exact-build function.
// @category Shoji
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import java.io.File;
import java.io.PrintWriter;

public class ExportCandidateDebug extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 2) {
            throw new IllegalArgumentException("usage: ExportCandidateDebug.java state.xml output.c");
        }
        if (!"b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673"
            .equals(currentProgram.getExecutableSHA256())) {
            throw new IllegalStateException("unsupported artifact");
        }
        Function function = getFunctionAt(toAddr(0x1873f6260L));
        if (function == null) {
            throw new IllegalStateException("candidate missing");
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.setOptions(new DecompileOptions());
        decompiler.openProgram(currentProgram);
        try {
            decompiler.enableDebug(new File(args[0]));
            DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
            if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
                throw new IllegalStateException("decompilation failed: " + result.getErrorMessage());
            }
            try (PrintWriter out = new PrintWriter(new File(args[1]), "UTF-8")) {
                out.print(result.getDecompiledFunction().getC());
            }
            println("CANDIDATE_DEBUG_STATE=" + args[0] + " C_OUTPUT=" + args[1]);
        } finally {
            decompiler.dispose();
        }
    }
}
