/*
 *  Main authors:
 *    Mikael Almgren <mialmg@kth.se>
 *    Mats Carlsson <matsc@sics.se>
 *    Roberto Castaneda Lozano <rcas@sics.se>
 *
 *  This file is part of Unison, see http://unison-code.github.io
 *
 *  Copyright (c) 2015-2016, Mikael Almgren
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

#include "dominance.hpp"

/*****************************************************************************
    Helper functions
*****************************************************************************/
// vector<int> sunion(vector<int> s1,
// 		   vector<int> s2) {
//   vector<int> temp(s1.size() + s2.size());
//   vector<int>::iterator it = set_union(s1.begin(), s1.end(),
// 				       s2.begin(), s2.end(),
// 				       temp.begin());
//   temp.resize(it - temp.begin());
//   return temp;
// }

bool compression_1(const vector<vector<int>>& S) {
  if(S[0].size() >= 2) {
    bool ex = false;

    for(const vector<int>& s1 : S) {
      ex = false;

      for(const vector<int>& s2 : S) {
	vector<int> s1_r(next(s1.begin()), s1.end());

	if(s1[0] != s2[0]) {
	  vector<int> s2_r(next(s2.begin()), s2.end());

	  if(s1_r == s2_r)
	    ex = true;
	}
      }
      if(!ex)
	return false;
    }
    return true;
  }

  // if the rows in S only has one column, return true if
  // there are one row with 1 and one with 0
  else if(S[0].size() == 1){
    bool ex = false;
    for(const vector<int>& s1 : S) {
      ex = false;
      for(const vector<int>& s2 : S)
	if(s1 != s2)
	  ex = true;

      if(!ex)
	return false;
    }
    return true;
  }
  return false;
}

int compression_2(const vector<vector<int>>& S, const vector<int>& O) {
  int ind = -1;

  for(uint o = 0; o < O.size(); o++) {
    for(const vector<int>& s : S) {
      if(s[o] == 1)
	ind = o;

      else {
	ind = -1;
	break;
      }
    }
    if(ind >= 0)
      break;
  }

  return ind;
}

bool compression_3(const vector<vector<int>>& S) {
  bool b = true;
  for(uint i = 0; i < S.size()-1; i++) {
    if(S[i].back() != 0) {
      b = false;
      break;
    }
  }
  if(b) {
    for(int s : S.back()) {
      if(s != 1) {
	b = false;
	break;
      }
    }
  }
  return b;
}

vector<vector<temporary>> sort_increasing_T(const map<vector<temporary>,vector<temporary>>& M) {
  vector<vector<temporary>> ret_keys;

  // Store all keys in new vector
  for(auto it = M.begin(); it != M.end(); it++) {
    ret_keys.push_back(it->first);
  }

  sort(ret_keys.begin(), ret_keys.end(),
       [M](vector<temporary> a, vector<temporary> b) {
  	 int a_size = M.at(a).size();
	 int b_size = M.at(b).size();

	 if(a_size == b_size) {
	   return a < b;
	 }
	 return a_size < b_size;
      });
  return ret_keys;
}

/*****************************************************************************
    Code related to:
    - JSON.domops
*****************************************************************************/
void temp_domination(Parameters & input) {
  map<tuple<vector<temporary>,vector<instruction>>,vector<temporary>> M;
  map<vector<temporary>,vector<operand>> N;

  for(operation o : input.O) {
    if(input.type[o] == COPY) {
      vector<instruction> instrs = input.instructions[o];
      auto key = make_tuple(opnd_temps_but_null(input, first_use(input, o)), instrs);
      temporary min_tmp = first_temp_but_null(input, first_def(input, o));

      vector_insert(M[key], min_tmp);
    }
  }

  for(operand p : input.P) {
    if(input.use[p]) {
      vector<temporary> T_temp = opnd_temps_but_null(input, p);
      vector<temporary> T = {T_temp.begin(), T_temp.end()};

      if(T.size() >= 3) {
      	for(auto it = M.begin(); it != M.end(); it++) {
	  tuple<vector<temporary>, vector<instruction>> k = it->first;
	  vector<temporary> T2 = get<0>(k);
	  vector<temporary> T1 = M.at(k);

	  if(*(T2.begin()) == *(T.begin()) && subseteq(T1, T) && T1.size() >= 2)
	    vector_insert(N[T1], p);
	}
      }
    }
  }

  // Generate the return set "domops"
  for (auto it = N.cbegin(); it != N.cend(); it++) {
    vector<int> T1 = it->first;
    vector<int> P = it->second;
    input.domops.push_back({P, T1});
  }
}

/*****************************************************************************
    Code related to:
    - JSON.dominates
*****************************************************************************/
void gen_dominates(Parameters & input) {
  map<temporary, vector<operation>> M;
  for(operation o : input.O) {
    if(input.type[o] == COPY && input.instructions[o][0] == NULL_INSTRUCTION) {
      temporary k = opnd_temps(input, first_use(input, o))[1];
      M[k].push_back(o);
    }
  }

  for(auto it = M.begin(); it != M.end(); it++) {
    for(operation o1 : it->second) {
      vector<instruction> I1 = oper_insns(input, o1);
      vector<temporary> D1 = opnd_temps(input, first_def(input, o1));
      vector<temporary> U1 = opnd_temps(input, first_use(input, o1));
      for(operation o2 : it->second) {
	if(o2 > o1) {
	  vector<instruction> I2 = oper_insns(input, o2);
	  vector<temporary> U2 = opnd_temps(input, first_use(input, o2));
	  PresolverDominates pd;
	  pd.o1 = o1;
	  pd.o2 = o2;
	  pd.ins = ord_difference(I2, I1);
	  pd.temps = ord_difference(ord_difference(U2, U1), D1);
	  input.dominates.push_back(pd);
	  if(subseteq(I1,I2) && subseteq(U2,U1))
	    break;
	}
      }
    }
  }
}

/*****************************************************************************
    Code related to:
    - JSON.instr_cond
*****************************************************************************/
void gen_instr_cond(Parameters & input) {
  for(operation o : input.O) {
    unsigned int nbins = input.instructions[o].size();
    unsigned int nbopnd = input.operands[o].size();
    if(nbins>=2) {
      for(unsigned int i=0; i<nbins; i++) {
	for(unsigned int j=0; j<nbins; j++) {
	  if(i!=j && input.rclass[o][i]==input.rclass[o][j]) {
	    unsigned int zo = nbopnd;
	    for(unsigned int k=0; k<nbopnd; k++) {
	      if(input.lat[o][i][k]==0 && input.lat[o][j][k]==-1 && k<zo) {
		zo = k;
	      } else if(input.lat[o][i][k]!=input.lat[o][j][k]) {
		goto nextj;
	      }
	    }
	    if(zo < nbopnd) {
	      PresolverInstrCond ic;
	      ic.o = o;
	      ic.i = input.instructions[o][j];
	      ic.q = input.operands[o][zo];
	      input.instr_cond.push_back(ic);
	    }
	  }
	nextj: ;
	}
      }
    }
  }
}

/*****************************************************************************
    Code related to:
    - JSON.active_tables
    - JSON.optional_min
    - JSON.tmp_tables
*****************************************************************************/
void gen_active_tables(Parameters & input, Support::Timer & t,
                       PresolverOptions & options) {

  // Post constraints
  ModelOptions moptions;
  RelaxedModel * base = new RelaxedModel(&input, &moptions, IPL_DOM);
  Gecode::SpaceStatus ss = base->status();
  assert(ss != SS_FAILED);
  vector<vector<int>> keys;
  vector<vector<int>> keys2;
  map<vector<temporary>, vector<temporary>> M;

  for(const vector<operand>& copyrel1 : input.copyrel) {
    vector<temporary> copies;
    for(const operand p : copyrel1) {
      if (!input.use[p] && (copies.size()==0 || !is_mandatory(input, opnd_oper(input, p)))) {
	const temporary tt = first_temp_but_null(input, p);
	copies.push_back(tt);
      }
    }
    if (copies.size() >= 2) {
      temporary th = copies[0];
      vector<temporary> tmin = {th};
      vector_insert(keys, tmin);
      for(temporary tt : copies)
	if (tt != th)
	  vector_insert(M[tmin], tt);
    }
  }
  for(const presolver_conj& n : input.nogoods) {
    if(n.size() == 2 && n[0].size() == 3 && n[1].size() == 3
       && n[0][0] == PRESOLVER_OPERAND_TEMPORARY
       && n[1][0] == PRESOLVER_OPERAND_TEMPORARY) {

      operand p1 = n[0][1];
      operand p2 = n[1][1];

      temporary t1 = first_temp_but_null(input, p1);
      temporary t2 = first_temp_but_null(input, p2);

      if(t1 != t2) {
      	vector<temporary> T1(next(input.temps[p1].begin()), input.temps[p1].end());
      	vector<temporary> T2(next(input.temps[p2].begin()), input.temps[p2].end());

      	for (temporary t3 : ord_union(T1, T2)) {
  	  vector<temporary> t1t2 = {t1, t2};
  	  vector_insert(M[t1t2], t3);

	  vector_insert(keys2, t1t2);
      	}
      }
    }
  }

  keys.insert(keys.end(), keys2.begin(), keys2.end());

  // Time quantum for assert_active_tables: 50% of time left
  int tqa = (options.timeout() - t.stop()) / 2;
  assert_active_tables(input, base, M, keys, tqa);

  // Time quantum for assert_tmp_tables: 95% of time left
  int tqt = 19*(options.timeout() - t.stop()) / 20;
  assert_tmp_tables(input, base, M, tqt);

  delete base;
}

void assert_active_tables(Parameters & input,
			  RelaxedModel * base,
			  const map<vector<temporary>,vector<temporary>>& M,
			  const vector<vector<int>>& keys,
			  int timeout) {

  vector<PresolverActiveTable> active_tables;

  Support::Timer t;
  for(const vector<int>& k : keys) {
    vector<operation> O;

    if(timeout <= 0)
      break;

    for(temporary t : M.at(k))
      O.push_back(input.def_opr[t]);

    vector<operand> P;
    for(operation o : O)
      for(operand p : input.operands[o])
	P.push_back(p);

    t.start();

    // Solve problem
    ActiveTableResult result = get_labelings(base, O, P, timeout);
    timeout -= (int) t.stop();

    // Store result of no timeout
    if(result.timeout_status == RELAXED_NO_TIMEOUT) {
      decompose_copy_set(input, O, result.labelings, active_tables);
    }

    else if(result.timeout_status == RELAXED_TIMEOUT)
      break;
  }
  input.active_tables = active_tables;
}

void decompose_copy_set(Parameters & input,
			const vector<operation>& O,
			const vector<vector<int>>& S,
			vector<PresolverActiveTable>& active_tables) {

  if(!(S.size() == 1 && S[0].empty()) && !O.empty()) {
    int ind = -1;	// index for stuck-at-1

    // The first variable is irrelevant
    // compression 1
    if(compression_1(S)) {
      vector<vector<int>> S1;
      vector<int> O1(next(O.begin()), O.end());

      for(const vector<int>& s : S) {
	if(s[0] == 0) {
	  vector<int> row(next(s.begin()), s.end());
	  S1.push_back(row);
	}
      }
      decompose_copy_set(input, O1, S1, active_tables);
    }

    // i:th variable stuck-at 1
    // compression 2
    else if((ind = compression_2(S, O)) >= 0) {
      PresolverActiveTable tmp{{O[ind]}, {{1}}};
      active_tables.push_back(tmp);
      vector<int> O1;

      for(int o : O)
	if(o != O[ind])
	  O1.push_back(o);

      vector<vector<int>> S1;
      for(const vector<int>& vs : S) {
	vector<int> temp_s;
	for(int i = 0; i < (int) vs.size(); i++)
	  if(i != ind)
	    temp_s.push_back(vs[i]);

	S1.push_back(temp_s);
      }
      decompose_copy_set(input, O1, S1, active_tables);
    }

    // The last variable implies the other variables
    // compression 3
    else if(O.size() >= 3 && compression_3(S)) {

      for(uint o = 0; o < O.size()-1; o++){
	PresolverActiveTable tmp{{O[o], O[O.size()-1]},
	                        {{0,0}, {1,0}, {1,1}}};
	active_tables.push_back(tmp);
      }
      vector<int> O1(O.begin(), O.end()-1);
      vector<vector<int>> S1;

      for(const vector<int>& vs : S) {
	if(vs != *(S.end()-1)) {
	  vector<int> temp_s(vs.begin(), vs.end()-1);
	  S1.push_back(temp_s);
	}
      }

      decompose_copy_set(input, O1, S1, active_tables);
    }

    else if(O.size() >= 1) {
      PresolverActiveTable tmp{O, S};
      active_tables.push_back(tmp);
    }
  }
}

void assert_tmp_tables(Parameters & input,
		       RelaxedModel * base,
		       const map<vector<temporary>,vector<temporary>>& M,
		       int timeout) {

  map<temporary, vector<operand>> P2U;
  vector<PresolverCopyTmpTable> tmp_tables;

  for(operand p : input.P) {
    if(input.use[p]) {
      if(!(input.temps[p].size() == 2 && input.temps[p][0] == -1)) {
	temporary tmin = first_temp_but_null(input, p);
	P2U[tmin].push_back(p);
      }
    }
  }

  Support::Timer t;
  for(const vector<temporary>& key : sort_increasing_T(M)) {
    if(key.size() == 1) {
      if(timeout <= 0)
	break;

      temporary k = key[0];
      vector<operation> O;

      for(temporary t : M.at(key))
	O.push_back(input.def_opr[t]);

      vector<operand> P = P2U.at(k);

      t.start();

      // Solve problem
      TmpTableResult result = get_labelings(input, base, O, P, timeout);
      timeout -= (int) t.stop();

      if(result.timeout_status == RELAXED_NO_TIMEOUT) {
	PresolverCopyTmpTable tmp_table{O, P, trim_tmp_tables(result.labelings, k)};
	tmp_tables.push_back(tmp_table);
      }

      else if(result.timeout_status == RELAXED_TIMEOUT)
	break;
    }
  }
  input.tmp_tables = tmp_tables;
}

vector<vector<int>> trim_tmp_tables(at_map S, temporary k) {

  vector<vector<int>> S1;
  for(auto it = S.begin(); it != S.end(); it++)
    for(vector<int> T : trim_clump(it->second, k))
      vector_insert(S1, {concat(it->first, T)});

  return S1;
}

vector<vector<int>> trim_clump(set<vector<int>> C, temporary k) {
  set<vector<int>> C_ret = C;

  for(auto it1 = C.begin(); it1 != C.end(); it1++)
    for(auto it2 = next(it1); it2 != C.end(); it2++)
      if(tmp_subsumes(*it1, *it2, k))
	C_ret.erase(*it2);

  return to_vector(C_ret);
}

bool tmp_subsumes(vector<int> T1, vector<int> T2, temporary k) {

  vector<int> T1_sorted = T1;
  vector<int> T2_sorted = T2;

  sort(T1_sorted.begin(), T1_sorted.end());  // If sorted are equal ->
  sort(T2_sorted.begin(), T2_sorted.end());  // permutation

  for(uint o = 0; o < T1.size(); o++)
    if(!((T1.at(o) == k) == (T2.at(o) == k)))
      return false;

  return T1_sorted == T2_sorted;
}

int optional_min_active_tables(Parameters& input, block b) {
  vector<operation> O = input.ops[b];
  int count = 0;

  for(const PresolverActiveTable& SR : input.active_tables) {
    if(subseteq(SR.os, O)) {
      O = ord_difference(O, SR.os);

      vector<int> sum_vector;

      for(const vector<int>& R : SR.tuples) {
	int temp_sum = 0;

	for(int r : R)
	  temp_sum += r;

	sum_vector.push_back(temp_sum);
      }
      count += min_of(sum_vector);
    }
  }
  return count;
}


void filter_active_tables(Parameters & input) {
  vector<PresolverActiveTable> filtered_active_tables;
  vector<operation> forced;
  vector<vector<operation>> pairs;
  vector<vector<int>> vi =  { {0, 0}, {1, 0}, {1, 1} };
  map<vector<operation>,vector<operation>> M;

  for(operation o : input.O) {
    const vector<operation>& act = input.activators[o];
    if (!act.empty())
      M[act].push_back(o);
  }
  for(const pair<vector<operation>,vector<operation>>& act_os : M) {
    for(operation o : input.O) {
      if(input.instructions[o][0]>0 && subseteq(input.instructions[o], act_os.first)) {
	for(block b : input.B) {
	  vector<operation> OSb = ord_intersection(act_os.second, input.ops[b]);
	  if(!OSb.empty()) {
	    vector<int> ones;
	    init_vector(ones, OSb.size(), 1);
	    filtered_active_tables.push_back({OSb,{ones}});
	  }
	}
	break;
      }
    }
  }

  for(const PresolverActiveTable& pa : input.active_tables) {
    if(pa.os.size() == 1) {
      filtered_active_tables.push_back(pa);
      vector_insert(forced, pa.os[0]);
    } else if(pa.tuples != vi) {
      filtered_active_tables.push_back(pa);
    } else {
      vector_insert(pairs, pa.os);
    }
  }

  vector<PresolverDominates> filtered_dominates;

  for(const PresolverDominates& pd : input.dominates) { // can be unsorted
    vector<operation> o12 = {pd.o1,pd.o2};
    if(!ord_contains(forced, pd.o1) && !ord_contains(pairs, o12))
      vector_insert(filtered_dominates, pd);
  }

  Digraph G = Digraph(pairs);
  Digraph GR = G.reduction();
  for(const edge& e : GR.edges()) {
    PresolverDominates pd;
    pd.o1 = e.first;
    pd.o2 = e.second;
    vector_insert(filtered_dominates, pd);
  }

  input.active_tables = filtered_active_tables;
  input.dominates = filtered_dominates;
}
