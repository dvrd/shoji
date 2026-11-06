// Explicit analysis hypotheses backed by caller instructions and SDK declarations.
// @category Shoji
import ghidra.app.script.GhidraScript;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.SourceType;
import java.util.HashSet;
import java.util.Set;

public class SetOrderingPrototypes extends GhidraScript {
    private void signature(Function function, DataType result, DataType... arguments) throws Exception {
        Parameter[] parameters = new Parameter[arguments.length];
        for (int i = 0; i < arguments.length; i++) {
            parameters[i] = new ParameterImpl("arg" + i, arguments[i], currentProgram);
        }
        function.setCallingConvention("__cdecl");
        function.setReturnType(result, SourceType.USER_DEFINED);
        function.replaceParameters(Function.FunctionUpdateType.DYNAMIC_STORAGE_ALL_PARAMS,
            true, SourceType.USER_DEFINED, parameters);
    }

    @Override
    public void run() throws Exception {
        if (!"default".equals(currentProgram.getCompilerSpec().getCompilerSpecID().getIdAsString())) {
            throw new IllegalStateException("requires AppleSilicon default C/C++ compiler model");
        }
        if (!"b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673"
            .equals(currentProgram.getExecutableSHA256())) {
            throw new IllegalStateException("unsupported artifact");
        }
        DataType ptr = PointerDataType.dataType;
        DataType integer = IntegerDataType.dataType;
        DataType uint = UnsignedIntegerDataType.dataType;
        DataType size = UnsignedLongLongDataType.dataType;
        DataType byteType = UnsignedCharDataType.dataType;
        DataType none = VoidDataType.dataType;
        Function candidate = getFunctionAt(toAddr(0x1873f6260L));
        if (candidate == null) {throw new IllegalStateException("candidate missing");}
        signature(candidate, integer, ptr, new PointerDataType(uint),
            new PointerDataType(integer), new PointerDataType(uint), uint, BooleanDataType.dataType);
        setPlateComment(candidate.getEntryPoint(),
            "ANALYSIS MODEL: six arguments from symbol/instructions; integer return consumed by " +
            "__XOrderWindow at 0x187528054. Native/Odin ABI, ownership and reentrancy not runtime verified.");
        int count = 0;
        Set<String> names = new HashSet<>();
        FunctionIterator functions = currentProgram.getFunctionManager().getExternalFunctions();
        while (functions.hasNext()) {
            Function function = functions.next();
            switch (function.getName()) {
                case "_free": signature(function, none, ptr); break;
                case "__platform_memset": signature(function, ptr, ptr, integer, size); break;
                case "_malloc_type_malloc": signature(function, ptr, size, size); break;
                case "_os_log_type_enabled": signature(function, BooleanDataType.dataType, ptr, byteType); break;
                case "__os_log_impl":
                    signature(function, none, ptr, ptr, byteType, ptr, new PointerDataType(byteType), uint);
                    break;
                case "___stack_chk_fail":
                    signature(function, none);
                    function.setNoReturn(true);
                    break;
                default: continue;
            }
            println("EXTERNAL_MODEL=" + function.getName(true) + " @ " + function.getEntryPoint());
            names.add(function.getName());
            count++;
        }
        println("EXPLICIT_CANDIDATE_MODEL=1 EXTERNAL_PROTOTYPES=" + count);
        println("UNIQUE_EXTERNAL_MODELS=" + names.size());
        if (names.size() != 6) {throw new IllegalStateException("expected six distinct candidate external prototypes");}
    }
}
