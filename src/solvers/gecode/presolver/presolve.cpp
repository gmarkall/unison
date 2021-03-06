/*
 *  Main authors:
 *    Mats Carlsson <matsc@sics.se>
 *    Roberto Castaneda Lozano <rcas@sics.se>
 *
 *  Contributing authors:
 *    Erik Ekstrom <eeks@sics.se>
 *    Noric Couderc <noric@sics.se>
 *
 *  This file is part of Unison, see http://unison-code.github.io
 *
 *  Copyright (c) 2016, SICS Swedish ICT AB
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions are met:
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. Neither the name of the copyright holder nor the names of its
 *     contributors may be used to endorse or promote products derived from this
 *     software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 *  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 *  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 */


#include "presolve.hpp"

void presolve(Parameters & input, PresolverOptions & options) {

  Support::Timer t;
  t.start();

  PresolverAsserts PA; // for holding some "global variables"

  // Precompute data-dependency graphs and their transposes
  vector<edge> noedges;
  Digraph emptyg = Digraph(noedges);
  init_vector(PA.dd_graph, input.B.size(), emptyg);
  init_vector(PA.dd_graph_transpose, input.B.size(), emptyg);
  for(block b : input.B) {
    Digraph dd = dd_graph(input, b);
    PA.dd_graph[b] = dd;
    PA.dd_graph_transpose[b] = dd.transpose();
  }

  // Precompute set of rematerialized temporaries
  for(const vector<operand>& copy_rels : input.copyrel)  {
    operand pprim = copy_rels[0];
    for(operand p : copy_rels) {
      operation o = input.oper[p];
      vector<temporary> ts = input.temps[p];
      if(p != pprim && !input.use[p] && ts[0] == NULL_TEMPORARY && input.type[o] != COPY && !input.delimiter[o]) {
	vector_insert(PA.remat, ts[1]);
      }
    }
  }

  // Clear all fields that will be generated.
  vector<PresolverBefore> before_ref = input.before;
  vector<nogood> nogoods_ref = input.nogoods;
  vector<vector<operand> > congr_ref = input.strictly_congr;
  vector<operand> last_use_ref = input.last_use;
  vector<temporary> unsafe_temp_ref = input.unsafe_temp;
  vector<vector<operand> > difftemps_ref = input.difftemps;
  vector<vector<operand> > diffregs_ref = input.diffregs;
  vector<vector<vector<int> > > domops_ref = input.domops;
  vector<PresolverAcross> across_ref = input.across;
  vector<PresolverSetAcross> set_across_ref = input.set_across;
  vector<PresolverBefore> before2_ref = input.before2;
  vector<nogood> nogoods2_ref = input.nogoods2;
  vector<PresolverPrecedence> precedences_ref = input.precedences;
  vector<PresolverPrecedence> precedences2_ref = input.precedences2;
  vector<vector<operation>> calleesaved_spill_ref = input.calleesaved_spill;
  vector<PresolverInstrCond> instr_cond_ref = input.instr_cond;
  vector<PresolverValuePrecedeChain> value_precede_chains_ref = input.value_precede_chains;
  vector<PresolverPred> predecessors_ref = input.predecessors;
  vector<PresolverSucc> successors_ref = input.successors;
  vector<vector<operand> > quasi_adjacent_ref = input.quasi_adjacent;
  vector<PresolverActiveTable> active_tables_ref = input.active_tables;
  vector<PresolverCopyTmpTable> tmp_tables_ref = input.tmp_tables;
  vector<PresolverDominates> dominates_ref = input.dominates;
  vector<int> optional_min_ref = input.optional_min;

  input.before.clear();
  input.nogoods.clear();
  input.strictly_congr.clear();
  input.last_use.clear();
  input.unsafe_temp.clear();
  input.difftemps.clear();
  input.diffregs.clear();
  input.domops.clear();
  input.across.clear();
  input.set_across.clear();
  input.before2.clear();
  input.nogoods2.clear();
  input.precedences.clear();
  input.precedences2.clear();
  input.calleesaved_spill.clear();
  input.instr_cond.clear();
  input.value_precede_chains.clear();
  input.predecessors.clear();
  input.successors.clear();
  input.quasi_adjacent.clear();
  input.active_tables.clear();
  input.tmp_tables.clear();
  input.dominates.clear();
  if (timeout(t, options, "preparation")) return;

  // 1: JSON.strictly_congr <- GENCONGR()

  gen_congr(input);
  if (timeout(t, options, "congr")) return;

  // 2: JSON.last_use <- LASTUSE()

  last_use(PA, input);
  if (timeout(t, options, "last_use")) return;

  // 3: JSON.unsafe_temp <- GENUNSAFETEMP()

  gen_unsafe_temp(input);
  if (timeout(t, options, "unsafe_temp")) return;

  // 4: <JSON.before, Nogoods0> <- BEFOREVSNOGOODS(GENBEFORE())

  vector<nogood> Nogoods;
  BeforePresolver::presolve(input, Nogoods);
  if (timeout(t, options, "before")) return;

  // 5: <Alldiffs, Nogoods1> <- GENINFEASIBLE()

  vector<temporand_set > Alldiffs;
  vector<nogood> Nogoods1;
  InfeasiblePresolver ip = InfeasiblePresolver(PA, input, t, options);
  ip.setup();
  ip.pass1(Alldiffs, Nogoods1);

  if (timeout(t, options, "gen_infeasible pass 1")) return;

  // 6: JSON.difftemps <- DIFFTEMPS() UNION Assert.cur_difftemp

  diff_temps(input);
  input.difftemps = ord_union(input.difftemps, PA.cur_difftemp);
  if (timeout(t, options, "difftemps")) return;

  // 7: JSON.diffregs <- {STRIP(D) | D IN Alldiffs}

  for (const temporand_set& D : Alldiffs)
    input.diffregs.push_back(strip(D));
  if (timeout(t, options, "diffregs")) return;

  // 8: JSON.domops <- TEMPDOMINATION()

  temp_domination(input);
  if (timeout(t, options, "domops")) return;

  // 9, 10: JSON.set_across + <Across,AltAcross,CondBefore,Nogoods2>

  vector<PresolverAcrossTuple> Across;
  vector<PresolverSetAcrossTuple> AltAcross;
  vector<PresolverBefore> CondBefore;
  vector<nogood> Nogoods2;
  presolve_across(PA, input, Across, AltAcross, CondBefore, Nogoods2);
  alt_across_to_json(input, AltAcross);
  if (timeout(t, options, "set_across")) return;

  // 11: Nogoods3 <- KERNELSET (Nogoods UNION Nogoods1 UNION Nogoods2, {})

  vector<nogood> n0, n1;

  set_union(Nogoods.begin(), Nogoods.end(),
	    Nogoods1.begin(), Nogoods1.end(),
	    back_inserter(n0));
  set_union(n0.begin(), n0.end(),
	    Nogoods2.begin(), Nogoods2.end(),
	    back_inserter(n1));
  Nogoods = kernel_set(n1, {});

  if (timeout(t, options, "Nogoods3")) return;

  // 12: DNogoods <-
  //     {{eq(p(p), p(q))}, {eq(p(p), t(t)), eq(p(q), t(t))}
  //            | t in OPNDTEMPS(p) /\ {p, q} SUBSETOF c /\ c IN JSON.difftemps}

  vector<nogood> DNogoods;
  for(const vector<operand>& c : input.difftemps) {
    if(c.size() >= 2) {
      for(unsigned i = 0; i < c.size(); i++) {
	for(unsigned j = i+1; j < c.size(); j++) {
	  operand p = c[i];
	  operand q = c[j];
	  for(temporary t : input.temps[p]) {
 	    vector_insert(DNogoods, {{0, p, q}});
	    vector_insert(DNogoods, {{1, p, t},{1, q, t}});
	  }
	}
      }
    }
  }

  if (timeout(t, options, "DNogoods")) return;

  // 13: Nogoods <- KERNELSET(DNogoods, Nogoods3)

  Nogoods = kernel_set(DNogoods, Nogoods);
  if (timeout(t, options, "Nogoods")) return;

  // 14: JSON.across <- AcrossToJson(Across, Nogoods)

  across_to_json(input, Across, Nogoods);
  if (timeout(t, options, "across")) return;

  // 15: MoreNogoods <- KernelSet(Assert.more_nogood, Nogoods)

  vector<nogood> MoreNogoods = kernel_set(PA.more_nogoods, Nogoods);
  if (timeout(t, options, "MoreNogoods")) return;

  // 16: JSON.nogoods2 <- MoreNogoods \ Nogoods

  input.nogoods2 = ord_difference(MoreNogoods, Nogoods);
  if (timeout(t, options, "nogoods2")) return;

  // 17: JSON.before2 <- {<p,q,d'> | <p,q,d> in CondBefore, d' = FilterCondition(d,MoreNogoods) where d' != {}}

  for(PresolverBefore& bef : CondBefore) {
    bef.d = filter_condition(bef.d, MoreNogoods);
    if(bef.d.size()>0)
      vector_insert(input.before2, bef);
  }
  if (timeout(t, options, "before2")) return;

  // 18: Precedences <- GenBeforePrecedences() U GenFixedPrecedences() U GenDataPrecedences()

  map<operand, map<instruction, latency>> opnd2lat = compute_opnd_to_lat(input);
  precedence_set precedences;
  gen_before_precedences(input, input.before, precedences);
  gen_fixed_precedences(input, precedences);
  gen_data_precedences(input, opnd2lat, precedences);
  gen_region_precedences(input, precedences);
  sort(precedences.begin(), precedences.end());
  precedences.erase(unique(precedences.begin(), precedences.end()), precedences.end());
  if (timeout(t, options, "Precedences")) return;

  // 19: JSON.precedences <- NormalizePrecedences()

  precedence_set temp;
  for(const PresolverPrecedence& pred : precedences) {
    operation p = pred.i;
    operation q = pred.j;
    int n = pred.n;
    presolver_disj b = pred.d;
    presolver_disj b1 = filter_condition(b, Nogoods);
    if(!b1.empty()) {
      PresolverPrecedence elem(p, q, n, b1);
      vector_insert(temp, elem);
    }
  }
  normalize_precedences(input, temp, input.precedences);
  if (timeout(t, options, "precedences")) return;

  // 20: JSON.precedences2 <- NormalizePrecedences()

  temp.clear();
  precedence_set precedences2;
  gen_before_precedences(input, input.before2, precedences2);
  for(const PresolverPrecedence& pred : precedences2) {
    operation p = pred.i;
    operation q = pred.j;
    int n = pred.n;
    presolver_disj b = pred.d;
    presolver_disj b1 = filter_condition(b, Nogoods);
    if(!b1.empty()) {
      PresolverPrecedence elem(p, q, n, b1);
      vector_insert(temp, elem);
    }
  }
  normalize_precedences(input, temp, input.precedences2);
  if (timeout(t, options, "precedences2")) return;

  // 21: JSON.calleesaved_spill

  gen_calleesaved_spill(input);
  if (timeout(t, options, "calleesaved_spill")) return;

  // 22: JSON.dur

  for (instruction i : input.I)
    for (resource r : input.R)
      if (input.con[i][r]==0)
	input.dur[i][r] = 1;
  if (timeout(t, options, "dur")) return;

  // 23: JSON.instr_cond

  gen_instr_cond(input);
  if (timeout(t, options, "instr_cond")) return;

  // 24: JSON.value_precede_chains

  input.value_precede_chains = value_precede_chains(input, NULL, true, -1);
  if (timeout(t, options, "value_precede_chains")) return;

  // 25: JSON.predecessors
  // 26: JSON.successors

  // gen_predecessors_successors(input);
  // if (timeout(t, options, "predecessors, successors")) return;

  // 25: JSON.quasi_adjacent

  quasi_adjacent(input);
  if (timeout(t, options, "quasi_adjacent")) return;

  // 26: GENDOMINATES()

  gen_dominates(input);
  if (timeout(t, options, "gen_dominates")) return;

  // 27: DETECTCYCLES(Nogoods)

  vector<nogood> Nogoods3, n3;

  ip.pass2(Nogoods3);

  set_union(Nogoods.begin(), Nogoods.end(),
	    Nogoods3.begin(), Nogoods3.end(),
	    back_inserter(n3));
  Nogoods = kernel_set(n3, {});

  if (timeout(t, options, "gen_infeasible pass 2")) return;

  ip.detect_cycles();

  if (timeout(t, options, "detect_cycles")) return;

  // 28: JSON.nogoods <- KERNELSET(Assert.new_nogood, Nogoods) \ DNogoods

  input.nogoods = ord_difference(kernel_set(PA.new_nogood, Nogoods), DNogoods);
  if (timeout(t, options, "nogoods")) return;

  // 29: GENACTIVETABLES(), JSON.tmp_tables

  input.compute_derived();	// refresh for Model:: methods
  gen_active_tables(input, t, options);
  if (timeout(t, options, "gen_active_tables")) return;

  // 30: FILTERACTIVETABLES(), JSON.active_tables, JSON.dominates

  filter_active_tables(input);	// sets input.active_tables, input.dominates
  if (timeout(t, options, "filter_active_tables")) return;

  // 31: for all b ∈ JSON.B do
  // 32: JSON.optional_min[b] <- OPTIONALMINACTIVETABLES(b)
  // 33: end for

  for(block b : input.B)
    input.optional_min[b] = optional_min_active_tables(input, b);
  if (timeout(t, options, "optional_min")) return;

  // these can cause huge printouts and should be protected from timeouts

  if (options.test()) {
    run_test("nogoods", nogoods_ref, input.nogoods);
    run_test("congr", congr_ref, input.strictly_congr);
    run_test("last_use", last_use_ref, input.last_use);
    run_test("unsafe_temp", unsafe_temp_ref, input.unsafe_temp);
    run_test("before", before_ref, input.before);
    run_test("difftemps", difftemps_ref, input.difftemps);
    run_test("diffregs", diffregs_ref, input.diffregs);
    run_test("domops", domops_ref, input.domops);
    run_test("across", across_ref, input.across);
    run_test("set_across", set_across_ref, input.set_across);
    run_test("before2", before2_ref, input.before2);
    run_test("nogoods2", nogoods2_ref, input.nogoods2);
    run_test("precedences", precedences_ref, input.precedences);
    run_test("precedences2", precedences2_ref, input.precedences2);
    run_test("calleesaved_spill", calleesaved_spill_ref, input.calleesaved_spill);
    run_test("instr_cond", instr_cond_ref, input.instr_cond);
    run_test("value_precede_chains", value_precede_chains_ref, input.value_precede_chains);
    run_test("predecessors", predecessors_ref, input.predecessors);
    run_test("successors", successors_ref, input.successors);
    run_test("quasi_adjacent", quasi_adjacent_ref, input.quasi_adjacent);
    run_test("dominates", dominates_ref, input.dominates);
    run_test("optional_min", optional_min_ref, input.optional_min);
    run_test("active_tables", active_tables_ref, input.active_tables);
    run_test("tmp_tables", tmp_tables_ref, input.tmp_tables);
  }
}
