// Add a partial state layout justified by stride and field accesses, not source recovery.
// @category Shoji
import ghidra.app.script.GhidraScript;
import ghidra.program.model.data.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.SourceType;

public class RefineOrderingState extends GhidraScript {
    private void parameters(long address, DataType... types) throws Exception {
        Function function = getFunctionAt(toAddr(address));
        if (function == null) {throw new IllegalStateException("missing function");}
        Parameter[] params = new Parameter[types.length];
        for (int i = 0; i < types.length; i++) {
            params[i] = new ParameterImpl("arg" + i, types[i], currentProgram);
        }
        function.setCallingConvention("__cdecl");
        function.setReturnType(VoidDataType.dataType, SourceType.USER_DEFINED);
        function.replaceParameters(Function.FunctionUpdateType.DYNAMIC_STORAGE_ALL_PARAMS,
            true, SourceType.USER_DEFINED, params);
    }

    @Override
    public void run() throws Exception {
        if (!"b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673"
            .equals(currentProgram.getExecutableSHA256())) {throw new IllegalStateException("unsupported image");}
        StructureDataType state = new StructureDataType(
            new CategoryPath("/ShojiAnalysis"), "PartialOrderState32", 32);
        state.replaceAtOffset(0, PointerDataType.dataType, 8, "window_0",
            "Observed window pointer; pointee layout not recovered");
        state.replaceAtOffset(8, PointerDataType.dataType, 8, "window_8",
            "Observed relative window pointer; ownership not recovered");
        state.replaceAtOffset(16, Undefined8DataType.dataType, 8, "unknown_10", "Unmodeled slot");
        state.replaceAtOffset(24, IntegerDataType.dataType, 4, "operation_18", "Observed 32-bit operation");
        state.replaceAtOffset(28, Undefined4DataType.dataType, 4, "unknown_1c", "Unmodeled slot");
        DataType type = currentProgram.getDataTypeManager().resolve(state, DataTypeConflictHandler.DEFAULT_HANDLER);
        DataType statePtr = new PointerDataType(type);
        parameters(0x1873e8760L, PointerDataType.dataType, statePtr);
        parameters(0x1873e8c90L, PointerDataType.dataType, statePtr,
            UnsignedLongLongDataType.dataType, BooleanDataType.dataType);
        // Its symbol is disable_pip_zoom(); its instruction body consumes globals,
        // not incoming integer argument registers. This remains an analysis model.
        parameters(0x1874191b8L);
        setEOLComment(toAddr(0x1873e8ba0L),
            "STATIC TARGET INFERENCE: CAManager factory constructs CAWSManager; address point " +
            "0x1e87410d0 + slot 0x128 = 0x1e87411f8, decoded guest cache target " +
            "0x1874d53fc (invalidate_geometry_seed). Dynamic receiver not observed; no flow override applied.");
        println("PARTIAL_STATE_BYTES=" + type.getLength() + " HELPER_MODELS=3 FLOW_OVERRIDES=0");
    }
}
