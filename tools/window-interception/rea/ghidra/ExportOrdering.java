// Export build-specific static evidence for Shoji's WindowServer investigation.
// @category Shoji
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.symbol.Reference;
import java.io.File;
import java.io.PrintWriter;
import java.util.LinkedHashSet;
import java.util.Set;

public class ExportOrdering extends GhidraScript {
    private static boolean relevant(String name) {
        return name.contains("CGXOrderWindowList") ||
            name.contains("PKGTransactionOrderWindow") ||
            name.contains("PKGTransactionSafeOrderWindowGroup") ||
            name.contains("start_order_window") ||
            name.contains("finish_order_windows") ||
            name.contains("WSWindowUpdateOrderedIn") ||
            name.equals("__XOrderWindow");
    }

    private void dumpFunction(PrintWriter out, Function function, DecompInterface decompiler) {
        out.println("\n===== " + function.getName() + " @ " + function.getEntryPoint() + " =====");
        out.println("signature=" + function.getSignature());
        out.println("body=" + function.getBody());
        out.println("callingConvention=" + function.getCallingConventionName());
        out.println("callers:");
        for (Reference reference : getReferencesTo(function.getEntryPoint())) {
            if (reference.getReferenceType().isCall()) {
                Function caller = getFunctionContaining(reference.getFromAddress());
                out.println("  " + reference.getFromAddress() + " " +
                    (caller == null ? "<no containing function>" : caller.getName()));
            }
        }
        out.println("instructions:");
        for (Instruction instruction : currentProgram.getListing().getInstructions(function.getBody(), true)) {
            out.println("  " + instruction.getAddress() + ": " + instruction);
        }
        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        out.println("decompiled:");
        if (result.decompileCompleted() && result.getDecompiledFunction() != null) {
            out.println(result.getDecompiledFunction().getC());
        } else {
            out.println("<unavailable: " + result.getErrorMessage() + ">");
        }
        out.flush();
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ExportOrdering.java output.txt");
        }
        Set<Function> selected = new LinkedHashSet<>();
        long[] entries = {0x1873f6260L, 0x187527f9cL};
        Function candidate = null;
        for (long entry : entries) {
            Address address = toAddr(entry);
            Function function = getFunctionAt(address);
            if (function == null) {
                throw new IllegalStateException("missing expected function at " + address);
            }
            selected.add(function);
            if (entry == entries[0]) {
                candidate = function;
            }
        }
        for (Reference reference : getReferencesTo(candidate.getEntryPoint())) {
            if (reference.getReferenceType().isCall()) {
                Function caller = getFunctionContaining(reference.getFromAddress());
                if (caller != null) {
                    selected.add(caller);
                }
            }
        }
        FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
        while (functions.hasNext()) {
            Function function = functions.next();
            if (relevant(function.getName())) {
                selected.add(function);
            }
        }
        if (selected.size() > 128) {
            throw new IllegalStateException("selected function limit exceeded: " + selected.size());
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter out = new PrintWriter(new File(args[0]), "UTF-8")) {
            out.println("program=" + currentProgram.getName());
            out.println("imageBase=" + currentProgram.getImageBase());
            out.println("selectedFunctions=" + selected.size());
            out.println("scope=static analysis only; indirect flows and runtime behavior remain unknown");
            for (Function function : selected) {
                if (monitor.isCancelled()) {
                    break;
                }
                dumpFunction(out, function, decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
