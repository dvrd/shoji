import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressRange;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.ReferenceIterator;

import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class FindOrderingCaves extends GhidraScript {
	private static final long TARGET = 0x1873f6260L;
	private static final long SPAN = 0x08000000L;
	private static final long MIN_GAP = 8;

	private static final class Interval {
		Address start, end;
		Interval(Address start, Address end) { this.start = start; this.end = end; }
	}

	@Override
	protected void run() throws Exception {
		if (getScriptArgs().length != 1) {
			throw new IllegalArgumentException("usage: FindOrderingCaves.java OUTPUT");
		}
		Address target = toAddr(TARGET);
		MemoryBlock containing = null;
		for (MemoryBlock block : currentProgram.getMemory().getBlocks()) {
			if (block.isExecute() && block.contains(target)) {
				containing = block;
				break;
			}
		}
		if (containing == null) {
			throw new IllegalStateException("target is not in an execute block");
		}
		Address lower = target.subtractNoWrap(Math.min(SPAN, target.subtract(containing.getStart())));
		Address upper = containing.getEnd();
		try { upper = target.add(SPAN); } catch (Exception ignored) {}
		if (upper.compareTo(containing.getEnd()) > 0) { upper = containing.getEnd(); }

		List<Interval> intervals = new ArrayList<>();
		FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
		while (functions.hasNext()) {
			Function function = functions.next();
			AddressSetView body = function.getBody();
			Address start = body.getMinAddress();
			Address end = body.getMaxAddress();
			if (start == null || end == null || end.compareTo(lower) < 0 || start.compareTo(upper) > 0) {
				continue;
			}
			if (start.compareTo(lower) < 0) { start = lower; }
			if (end.compareTo(upper) > 0) { end = upper; }
			intervals.add(new Interval(start, end));
		}
		intervals.sort(Comparator.comparing(a -> a.start));
		List<Interval> merged = new ArrayList<>();
		for (Interval interval : intervals) {
			if (merged.isEmpty()) {
				merged.add(interval);
				continue;
			}
			Interval last = merged.get(merged.size() - 1);
			if (interval.start.compareTo(last.end.add(1)) <= 0) {
				if (interval.end.compareTo(last.end) > 0) { last.end = interval.end; }
			} else {
				merged.add(interval);
			}
		}
		try (PrintWriter out = new PrintWriter(getScriptArgs()[0])) {
			out.printf("TARGET=0x%x BLOCK=%s 0x%x..0x%x FUNCTIONS=%d MERGED=%d%n",
				TARGET, containing.getName(), lower.getOffset(), upper.getOffset(), intervals.size(), merged.size());
			Address cursor = lower;
			List<Interval> gaps = new ArrayList<>();
			for (Interval interval : merged) {
				if (cursor.compareTo(interval.start) < 0) {
					gaps.add(new Interval(cursor, interval.start.subtract(1)));
				}
				if (cursor.compareTo(interval.end.add(1)) < 0) { cursor = interval.end.add(1); }
			}
			if (cursor.compareTo(upper) <= 0) { gaps.add(new Interval(cursor, upper)); }
			int reported = 0;
			for (Interval gap : gaps) {
				long size = gap.end.subtract(gap.start) + 1;
				if (size < MIN_GAP) { continue; }
				long zeros = 0, definedRefs = 0, errors = 0;
				for (Address address = gap.start; address.compareTo(gap.end) <= 0; address = address.add(1)) {
					try { if (getByte(address) == 0) { zeros++; } } catch (Exception ignored) { errors++; }
					ReferenceIterator references = currentProgram.getReferenceManager().getReferencesTo(address);
					if (references.hasNext()) { definedRefs++; }
				}
				out.printf("GAP 0x%x..0x%x size=%d zeros=%d refs_to_addresses=%d errors=%d distance=%d%n",
					gap.start.getOffset(), gap.end.getOffset(), size, zeros, definedRefs, errors,
					Math.abs(gap.start.getOffset() - TARGET));
				reported++;
			}
			out.printf("GAPS=%d REPORTED=%d%n", gaps.size(), reported);
		}
	}
}
