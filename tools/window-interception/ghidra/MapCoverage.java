// Maps the compositor function families relevant to window visibility:
// ordering, geometry, surfaces, visibility state, spaces, tiling and flush/
// commit paths. Static analysis only; read-only on the analyzed program.
// usage: analyzeHeadless <dir> <project> -process <program> -noanalysis \
//   -scriptPath <dir> -postScript MapCoverage.java <output>

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

public class MapCoverage extends GhidraScript {
    private static final Pattern FAMILY = Pattern.compile(
        "order|geometry|bounds|surface|visib|space|tile|level|opacity|transform|flush|commit|present|shield|menubar|menu_bar",
        Pattern.CASE_INSENSITIVE);
    private static final Pattern NOISE = Pattern.compile(
        "debug|log_|assert|trace|signpost|copyright|metaclass|_NS|_CF|objc_|swift_|descr|hash|equal|copy|init|alloc",
        Pattern.CASE_INSENSITIVE);
    private static final int MAX_CALLERS = 64;

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            printerr("usage: MapCoverage.java OUTPUT");
            return;
        }
        Set<String> seen = new LinkedHashSet<>();
        List<String> matches = new ArrayList<>();
        SymbolIterator symbols = currentProgram.getSymbolTable().getAllSymbols(true);
        while (symbols.hasNext()) {
            Symbol symbol = symbols.next();
            if (!symbol.isPrimary()) {
                continue;
            }
            String name = symbol.getName();
            if (!FAMILY.matcher(name).find() || NOISE.matcher(name).find()) {
                continue;
            }
            Function function = getFunctionAt(symbol.getAddress());
            if (function == null || !function.getName().equals(name)) {
                continue;
            }
            if (seen.add(name)) {
                matches.add(name);
            }
        }
        try (PrintWriter out = new PrintWriter(args[0])) {
            out.println("program=" + currentProgram.getName());
            out.println("imageBase=" + currentProgram.getImageBase().toString());
            out.println("familyFunctions=" + matches.size());
            out.println("scope=static analysis only; indirect flows and runtime behavior remain unknown");
            for (String name : matches) {
                Function function = null;
                SymbolIterator lookup = currentProgram.getSymbolTable().getSymbols(name);
                while (lookup.hasNext()) {
                    Symbol candidate = lookup.next();
                    Function found = getFunctionAt(candidate.getAddress());
                    if (found != null && found.getName().equals(name)) {
                        function = found;
                        break;
                    }
                }
                if (function == null) {
                    continue;
                }
                Address entry = function.getEntryPoint();
                out.println();
                out.println("===== " + name + " @ " + entry + " =====");
                out.println("callers:");
                int count = 0;
                for (Reference reference : getReferencesTo(entry)) {
                    Function caller = getFunctionContaining(reference.getFromAddress());
                    String label = caller != null ? caller.getName() : "data:" + reference.getFromAddress();
                    out.println("  " + reference.getFromAddress() + " " + label);
                    if (++count >= MAX_CALLERS) {
                        out.println("  ...truncated");
                        break;
                    }
                }
                out.println("calls:");
                for (Instruction instruction : currentProgram.getListing().getInstructions(function.getBody(), true)) {
                    if (!instruction.getFlowType().isCall()) {
                        continue;
                    }
                    for (Reference reference : instruction.getReferencesFrom()) {
                        Function target = getFunctionAt(reference.getToAddress());
                        if (target != null) {
                            out.println("  " + instruction.getAddress() + " " + target.getName());
                        }
                    }
                }
            }
        }
        println("coverage map written: " + args[0] + " functions=" + matches.size());
    }
}
