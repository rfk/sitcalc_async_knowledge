%
%  prover.pl:  a theorem prover for multi-agent epistemic first-order logic.
%
%  Copyright 2008-2014, Ryan Kelly
%
%  This is a theorem-prover for the variant of modal logic used in our
%  fluent domain, based on the ideas in leanTAP [1] and its expansion to
%  modal logic by Fitting [2].  It's a classic tableaux-style prover that
%  tries to refute a formula by closing all branches of its tableaux, and
%  it handles modalities by building an auxiliary tableaux for each new
%  modal world until it finds one that can be closed.
%
%  [1] Bernhard Beckert and Joachim Posegga.
%      leanTAP: Lean tableau-based deduction.
%      Journal of Automated Reasoning, 15(3):339-358, 1995.
%
%  [2] Melvin Fitting.
%      leanTAP Revisited
%      Journal of Logic and Computation, 8(1):33-47, 1998.
%
%  It is, sadly, a lot less "lean" than the source material due to several
%  additions that make it more suitable for use with situation calculus
%  domains:
%  
%    * Support for an distinct set of "axioms" which are known to hold
%      at all worlds in the model, to represent the background theory
%      of the domain.
%
%    * Special-case handling of term equality, assuming rigid terms and
%      unique-names axioms.
%
%    * Use of attributed variables to track each free variable back to
%      its source formula, and avoid making multiple instanciations of
%      the formula with the some variable bindings.
%
%    * More care taken to try to terminate when the tableaux cannot be
%      closed, since calculation of the persistence condition requires
%      a terminating decision procedure.
%
%  Our logical terms and operators are:
% 
%     true             -   truth literal (ie "top")
%     false            -   falsehood literal (ie "bottom")
%     p(...)           -   predicate, optionally with term arguments
%     A = B            -   term equality
%     ~P               -   negation
%     P & Q            -   logical and
%     P | Q            -   logical or
%     P => Q           -   implication
%     P <=> Q          -   equivalence
%     all([Xs], P)     -   universal quantification (positive scope only)
%     ~ext([Xs], P)    -   existential quantification (negative scope only)
%     knows(A,P)       -   agent knowledge modality
%
%  There is no support for existential quantification, this must be handled
%  handled in a pre-processing step.  Our treatment of equality-as-unification
%  means skolemization is not possible, so for now, existential quantifiers
%  will have to be expanded out into a finite disjunction of possibilities.
%
%  Most of these operators are native to prolog so we dont have to declare
%  them ourselves.  The all() and ext() terms takes a unique prolog-level
%  variable as its first argument; this variable will not be bound during the
%  proof search.
%

:- module(prover, [
    is_atom/1,
    is_literal/1,
    tbl_expand/3,
    prove/1,
    prove/2,
    op(200, fx, ~),
    op(500, xfy, <=>),
    op(500, xfy, =>),
    op(520, xfy, &)
]).

%
%  is_atom(P)    -  the formula P is a literal atom, not a compound expression
%  is_literal(P) -  the formula P is a literal atom or the negation of one
%
%  This can be used to detect the base case of predicates that structurally
%  decompose formulae.
%

is_atom(P) :-
  P \= (~_),
  P \= (_ => _),
  P \= (_ <=> _),
  P \= (_ & _),
  P \= (_ | _),
  P \= ext(_, _),
  P \= all(_, _),
  P \= knows(_, _).

is_literal(~P) :- !, is_atom(P).
is_literal(P) :- is_atom(P).


% 
%  prove/1 and prove/2:  top-level driver for the prover.
%
%  These predicates attempt to prove a formula by refuting its negation.
%  The optional set of axioms are formulae known to hold at all worlds
%  reachable in the model.  This list must not include any modalities,
%  or the prover may get stuck in a loop expanding copies of the same
%  modality over and over.
%

prove(Fml) :-
  prove([], Fml).

prove(Axioms, Fml) :-
  prove_iterdeep(Axioms, Fml, 500).

prove_iterdeep(Axioms, Fml, Limit) :-
  % Classic iterative-deepening for completeness, for which
  % swi-prolog conveniently provides builtin support via the
  % call_with_depth_limit/3 predicate.
  refute_with_depth_limit(Axioms, ~Fml, Limit, Result),
  ( Result = depth_limit_exceeded ->
      %write(not_proved_at_depth(Limit)), nl,
      NewLimit is Limit + 500,
      prove_iterdeep(Axioms, Fml, NewLimit)
  ;
      %write(proved_at_depth(Result)), nl
      true
  ).

refute_with_depth_limit(Axioms, Fml, Limit, Result) :-
  tbl_init(Axioms, Tbl),
  call_with_depth_limit(refute(Fml, Tbl), Limit, Result).

refute(Fml, Tbl) :-
  % Try to expand the given tableaux with the given formula so that
  % all branches are closed.  Since tbl_expand/3 generates all 'closed'
  % solutions before generating any 'open' solutions, we can safely
  % cut after the first solution and avoid lots of pointless backtracking.
  tbl_expand(Fml, Tbl, Res),
  !, Res=closed(_).


%
%  tbl_expand/3:  build a fully-expanded tableaux from the given state.
%
%  This is the core of the prover.  In the style of leanTaP, it takes the
%  current state of an under-construction tableaux and tries to expand it
%  into one where all branches are closed.  Unlike leanTaP, we use an explicit
%  "tableaux state" data structure to pass around the state, since our version
%  contains quite a few more auxiliary fields.
%
%  The state of the tableaux branch at each invocation represents a partially-
%  built model based at a particular world of the underlying kripke structure.
%
%  The expansion proceeds by expanding all formulae on the branch, trying
%  to produce a conflicting pair of literals at the current world that will
%  close the branch.  If this is not possible then one of the related worlds
%  implied by the model is selected and the search continues in a sub-tableaux
%  at that world.
%
%  If all branches are successfully closed, the predicate's third argument
%  will be bound to 'closed(NEqs)' where NEqs is a possibly-empty list of
%  pairs of terms that must not unify.  If some branch remains open then
%  its third argument will be bound to the atom 'open'.
%
%  All 'closed' solutions will be generated before any 'open' solutions.
%  

% Normalization rules.
% These decompose higher-level connectives into simpler ones by
% e.g. pushing negation inside other operators.  This effectively
% computes the required normal form at runtime.

tbl_expand(~(~X), Tbl, Res) :-
  !, tbl_expand(X, Tbl, Res).

tbl_expand(X => Y, Tbl, Res) :-
  !, tbl_expand((~X) | Y, Tbl, Res).

tbl_expand(X <=> Y, Tbl, Res) :- 
  !, tbl_expand((X & Y) | (~X & ~Y), Tbl, Res).

tbl_expand(~(X & Y), Tbl, Res) :-
  !, tbl_expand((~X) | (~Y), Tbl, Res).

tbl_expand(~(X | Y), Tbl, Res) :-
  !, tbl_expand(~X & ~Y, Tbl, Res).

tbl_expand(~(X => Y), Tbl, Res) :-
  !, tbl_expand(X & (~Y), Tbl, Res).
  
tbl_expand(~(X <=> Y), Tbl, Res) :-
  !, tbl_expand(((~X) | (~Y)) & (X | Y), Tbl, Res).

tbl_expand(~ext(Vs, P), Tbl, Res) :-
  !, tbl_expand(all(Vs, ~P), Tbl, Res).

%  Rule to handle universal quantification.
%  We create a new instance of the quantified formula using a fresh
%  variable, and stash the original formula in the tableaux state for
%  future re-use.  It will only be re-used if the previous instance of
%  that formula is bound during the search, to ensure that we don't keep
%  pointlessly re-using the same formula over and over.

tbl_expand(all([], P), Tbl, Res) :-
  !,
  tbl_expand(P, Tbl, Res).
tbl_expand(all([X|Xs], P), Tbl, Res) :-
  !,
  tbl_add_univ_fml(Tbl, all(X, all(Xs, P)), InstFml, Tbl2),
  tbl_expand(InstFml, Tbl2, Res).

%  Rule to guard against existential quantification.
%  Existential quantification is not supported, and must be handled as a
%  pre-processing step before passing formulae to the prover.  This rule
%  proides a simple sanity-check.

tbl_expand(ext(_, _), _, _) :-
  !, write(formula_cannot_contain_existential_quantifiers), nl, fail.

tbl_expand(~all(_, _), _, _) :-
  !, write(formula_cannot_contain_existential_quantifiers), nl, fail.

%  Rules for collecting modalities.
%  Modalities don't constrain the current world, but rather the worlds
%  that may be reachable from the current one.  They are simply collected
%  along the branch and used to imply/constraint other worlds that we might
%  move to if the current one cannot be closed.

tbl_expand(knows(A, F), Tbl, Res) :-
  !,
  tbl_add_necc(Tbl, k(A, F), Tbl2),
  tbl_expand(true, Tbl2, Res).

tbl_expand(~knows(A, F), Tbl, Res) :-
  !,
  tbl_add_poss(Tbl, k(A, ~F), Tbl2),
  tbl_expand(true, Tbl2, Res).

%  Rule for handling disjunction.
%  The tableaux bifurcates and we must try to close both branches, ensuring
%  that any declared non-unifiability of terms is respected across both
%  branches.
%
%  Note that our use of prolog variables when instantiating universally-
%  quantified formulae means that free-variable substitutions apply across
%  both branches, as required for a first-order tableaux.

tbl_expand(X | Y, Tbl, Res) :-
  !,
   % First try to close the LHS branch.
  tbl_expand(X, Tbl, ResX),
  ( ResX = closed(NEqsX) ->
    % Ensure that the RHS proof search doesn't unify things that the LHS
    % proof search declared must not unify.
    tbl_add_neqs(Tbl, NEqsX, Tbl2),
    tbl_expand(Y, Tbl2, ResY),
    ( ResY = closed(NEqsY) ->
      % Combine the things-that-must-not-unify lists from both branches.
      append(NEqsX, NEqsY, NEqs),
      Res = closed(NEqs)
    ;
      % The RHS could not be closed.
      % Backtrack to a different solution for the LHS.
      fail
    )
  ;
    % The LHS could not be closed, so the whole tableaux stays open.
    Res = open
  ).

%  Rule for handling conjunction.
%  Both sides simply get added to the existing branch.

tbl_expand(X & Y, Tbl, Res) :-
  !,
  tbl_push_fml(Tbl, Y, Tbl2),
  tbl_expand(X, Tbl2, Res).

%  Rule for closing the branch, or continuing the search.
%
%  The formula under consideration here must be a (possibly negated)
%  literal, since any other form would have matched a rule above.
%
%  We add the literal to the current tableaux state.  If that produces a
%  contradiction then we're done on this branch.  If not then the tableaux
%  remains open and we proceed as follows:
%
%    * If we have more unexpanded formulae on the branch, continue
%      expanding the current branch.
%
%    * If we have universal formulae where all instances have been used,
%      add fresh instances of them to the unexpanded list and continue
%      expanding the current branch.
%
%    * Enumerate the alternative worlds implied by the current tableaux
%      state, expanding a sub-tableaux for each:
%
%        * If any such sub-tableaux is closed, close the current branch.
%
%        * If all sub-tableaux remain open, check again for universal
%          formulae where all instances have been used.  If we have any
%          then add fresh instances of them to the unexpanded list and
%          resume expanding the current branch.
%
%    * Otherwise, there is no way to close the current branch, so report
%      it as being open.
%
%  This rather heavy-handled imperative control flow is designed to avoid
%  repeatedly instantiating the same universally-quantified formula over
%  and over, without stopping the search too early.  It has been found to
%  help termination in cases that obviously cannot be expanded to a closed
%  state, but for which a naive handling of universally-quantified formulae
%  would recurse forever.
%

tbl_expand(Lit, Tbl, Res) :-
  (
    tbl_add_literal(Tbl, Lit, Tbl2),
    ( Tbl2 = closed(NEqs) ->
      Res = closed(NEqs)
    ;
      ( tbl_pop_fml(Tbl2, Fml, Tbl3) ->
          tbl_expand(Fml, Tbl3, Res)
      ;
        tbl_copy_used_univ_fmls(Tbl2, Tbl3),
        ( tbl_pop_fml(Tbl3, Fml, Tbl4) ->
            tbl_expand(Fml, Tbl3, Res)
        ;
          tbl_expand_subtbls(Tbl2, SubRes),
          ( SubRes = closed(NEqs) ->
              Res = closed(NEqs)
          ;
            tbl_copy_used_univ_fmls(Tbl2, Tbl3),
            ( tbl_pop_fml(Tbl3, Fml, Tbl4) ->
              tbl_expand(Fml, Tbl3, Res)
            ;
              Res = open
            )
          )
        )
      )
    ) 
  ;
    % After all other possibilities have been exhaused, we want to make
    % sure to generate an 'open' solution so that failure-driven backtracking
    % will work correctly.
    Res = open
  ).


%  Helper predicate for expanding each sub-tableaux in turn.
%  This enumerates all the possible sub-tableaux and then walks the
%  list trying to close them.  It will unify its second argument with
%  'closed' if one of the sub-tableaux could be closed, and with 'open'
%  if they all remain open.
%
%  Like tbl_expand/3 this will backtrack over different possible ways
%  to close each sub-tableaux.

tbl_expand_subtbls(Tbl, Res) :-
  findall(SubTbl, tbl_pick_subtbl(Tbl, SubTbl), SubTbls),
  tbl_expand_subtbls(Tbl, SubTbls, Res).

tbl_expand_subtbls(_, [], open).
tbl_expand_subtbls(Tbl, [SubTbl | SubTbls], Res) :-
  tbl_expand(true, SubTbl, SubRes),
  ( SubRes = closed(NEqs) ->
      Res = closed(NEqs)
  ;
      tbl_expand_subtbls(Tbl, SubTbls, Res)
  ).


%
%  tbl_*  -  utility predicates for maintaining in-progess tableaux state.
%
%  The following are low-level state manipulation routines for the tableaux.
%  They're mostly just list-shuffling and could have been done inline in the
%  spirit of leanTaP, but factoring them out helps the code read better and
%  leaves the door open for e.g. better data structures.
%  
%  The full state of a tableaux branch is a term:
%
%      tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs)
%
%  Its arguments are:
%
%    * UnExp:   a list of formulae remaining to be expanded on the branch.
%    * TLits:   a list of literals true at the current world.
%    * FLits:   a list of literals false at the current world.
%    * NEqs:    a list of A=B pairs that are not allowed to unify.
%    * Axs:     a list of formulae true at every possible world.
%    * Necc:    a list of formulae that hold at all accessible worlds,
%               indexed by name of accessibility relation
%    * Poss:    a list of formulae that hold at some accessible world,
%               indexed by name of accessibility relation
%    * Univ:    a list of universally-quantified formulae that can be used
%               on the branch, along with previous instantiation variables.
%    * FVs:     a list of free variables instantiated by the prover, which
%               must be preserved when copying formulae.
%

%
%  tbl_init/2  -  initialize a new empty tableaux
%
%  This predicate takes a list of axioms that are true at every world,
%  and produces an initialized tableux state.
%

tbl_init(Axs, TblOut) :-
  TblOut = tbl(Axs, [], [], [], Axs, [], [], [], []).

tbl_write(Tbl) :-
  Tbl = tbl(UE, TLits, FLits, NEqs, _, Necc, Poss, Univ, _),
  write(tbl), nl,
  write('    UE = '), write(UE), nl,
  write('    TLits = '), write(TLits), nl,
  write('    FLits = '), write(FLits), nl,
  write('    NEqs = '), write(NEqs), nl,
  write('    Necc = '), write(Necc), nl,
  write('    Poss = '), write(Poss), nl,
  tbl_write_univ(Univ).

tbl_write_univ([]).
tbl_write_univ([U|Univ]) :-
  write('        Univ: '), write(U), nl,
  tbl_write_univ(Univ).

%
%  tbl_push_fml/3  -  add a formula to be expanded on this tableaux branch
%  tbl_pop_fml/3   -  pop a formula off the unexpanded list for this branch
%
%  These predicates simply push/push from a list of yet-to-be-expanded
%  formulae, basically maintaining a worklist for the current branch.
%

tbl_push_fml(TblIn, Fml, TblOut) :-
  TblIn = tbl(UE, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  TblOut = tbl([Fml|UE], TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs).

tbl_pop_fml(TblIn, Fml, TblOut) :-
  TblIn = tbl([Fml|UE], TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  TblOut = tbl(UE, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs).

%
%  tbl_add_neqs/3  - add non-unification constraints to the tableaux
%
%  This predicate declares that the list of [A=B] pairs in its second arugment
%  must not be made to unify, recording them in an internal list in the 
%  tableaux state.  Subsequent attempts to bind free variables will be
%  checked for compatability with this list.
%

tbl_add_neqs(TblIn, NEqs, TblOut) :-
  TblIn = tbl(UnExp, TLits, FLits, NEqsIn, Axs, Necc, Poss, Univ, FVs),
  append(NEqs, NEqsIn, NEqsOut),
  TblOut = tbl(UnExp, TLits, FLits, NEqsOut, Axs, Necc, Poss, Univ, FVs).

%
%  tbl_add_necc/4  - add a formula that holds at all possible worlds
%  tbl_add_poss/4  - add a formula that holds at some possible world
%
%  These predicates are used to accumulate information about worlds reachable
%  from the current one.  This information is then used to initialize a
%  sub-tableuax if the proof moves to a new world.
%

tbl_add_necc(TblIn, N, TblOut) :-
  TblIn = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  TblOut = tbl(UnExp, TLits, FLits, NEqs, Axs, [N|Necc], Poss, Univ, FVs).

tbl_add_poss(TblIn, P, TblOut) :-
  TblIn = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  TblOut = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, [P|Poss], Univ, FVs).

%
%  tbl_add_univ_fml/4  -  add a universally-quantified formula to the tableaux
%
%  This predicate is applied to universally-quantified formula found during
%  the expansion.  It produces an instance of the formula with a fresh variable
%  and notes the formula for potential re-use in the future.
% 

tbl_add_univ_fml(TblIn, all(X, P), InstFml, TblOut) :-
  TblIn = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  tbl_copy_term(TblIn, [X, P], [V, InstFml]),
  % Remember where this var come from, so we can avoid duplicate bindings.
  put_attr(V, prover, []),
  U = u(X, P, [V]),
  TblOut = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, [U|Univ], [V|FVs]).

%
%  tbl_copy_term/2  -  copy term while preserving unbound vars.
%
%  This predicate can be used like copy_term/2 expect that it will not
%  rename unbound free variables in the formula.  Basically it renames
%  variables defined outside of the proof search, while maintaining any
%  variables created by the search itself.
%

tbl_copy_term(Tbl, TermIn, TermOut) :-
  Tbl = tbl(_, _, _, _, _, _, _, _, FVs),
  copy_term([TermIn, FVs], [TermOut, FVs]).

%
%  tbl_copy_used_univ_fmls/2  -  make fresh copes of used universal formulae
%
%  This predicate finds any universally-quantified formula for which all
%  existing instances have been "used" - that is, have had their instance
%  variable bound.  If it finds any then it copies fresh instances of them
%  into the list of unexpanded formulae.
%
%  This is a simple way to avoid making lots of useless duplicate expansions
%  of universally-quantified formulae.
%

tbl_copy_used_univ_fmls(TblIn, TblOut) :-
  TblIn = tbl([], TLits, FLits, NEqs, Axs, Necc, Poss, UnivIn, FVs),
  TblOut = tbl(UnExp, TLits, FLits, NEqs, Axs, Necc, Poss, UnivOut, FVs),
  tbl_copy_used_univ_fmls_rec(TblIn, UnivIn, UnivOut, UnExp).

tbl_copy_used_univ_fmls_rec(_, [], [], []).
tbl_copy_used_univ_fmls_rec(Tbl, [U|UnivIn], UnivOut, UnExp) :-
  U = u(X, P, Vars),
  Vars = [PrevV|_],
  ( ( \+ var(PrevV) ) ->
      tbl_copy_term(Tbl, [X, P], [NewV, NewP]),
      % Remember where this var come from, so we can avoid duplicate bindings.
      put_attr(NewV, prover, Vars),
      UnivOut = [u(X, P, [NewV|Vars])|UnivOutRest],
      UnExp = [NewP|UnExpRest]
  ;
      UnivOut = [U|UnivOutRest],
      UnExp = UnExpRest
  ),
  tbl_copy_used_univ_fmls_rec(Tbl, UnivIn, UnivOutRest, UnExpRest).

%
%  tbl_pick_subtbl/2  -  generate a sub-tableaux for a related world
%
%  The tableaux state contains a collection of "possible" and "necessary"
%  formulae that imply the existence of other worlds related to the one
%  currently under consideration.  This predicate picks one such world
%  and returns a new tableaux based on the formulae relevant to that world8,
%  backtracking over each choice in turn.
%

tbl_pick_subtbl(Tbl, SubTbl) :-
  Tbl = tbl(_, _, _, NEqs, Axioms, Necc, Poss, _, FVs),
  % Pick a possible world.
  member(k(A, F), Poss),
  % Pair it with all the things that necessarily hold there.
  ( bagof(FN, member(k(A, FN), Necc), FNs) ->
    copy_term(Axioms, AXs),
    append(FNs, AXs, FNecc)
  ;
    copy_term(Axioms, FNecc)
  ),
  SubTbl = tbl([F|FNecc], [], [], NEqs, Axioms, [], [], [], FVs).


tbl_pick_subtbl(Tbl, SubTbl) :-
  Tbl = tbl(_, _, _, NEqs, Axioms, Necc, Poss, _, FVs),
  % Pick an agent for whom no possible world was implied.
  % We assume that they consider at least one world possible,
  % so we can check the consistency of their knowledge.
  setof(A, F^(member(k(A, F), Necc), \+ member(k(A, _), Poss)), AllA),
  member(A, AllA),
  % Pair it with all the things that necessarily hold there.
  ( bagof(FN, member(k(A, FN), Necc), FNs) ->
    copy_term(Axioms, AXs),
    append(FNs, AXs, FNecc)
  ;
    copy_term(Axioms, FNecc)
  ),
  SubTbl = tbl(FNecc, [], [], NEqs, Axioms, [], [], [], FVs).

%
%  tbl_add_literal/3  - expand the branch with a new literal
%
%  This predicate attempts to add a new literal to the branch.
%
%  It first tries to add it in such a way as to form a contradiction, in
%  which case the third argument is bound to closed(NEqs) with NEqs a list
%  of A=B pairs that must *not* be made to unify on some other branch.
%
%  If closing the branch fails, it adds the literal to the appropriate field
%  in the tableaux state and binds the third argument to the new tableaux.
%
%  This is really the heart of the prover, where the contrdictions are made.
%  It has special-case handling of equality based on rigid terms and unique
%  names axioms, meaning we can treat it using unification.
%

tbl_add_literal(Tbl, true, Tbl) :- !.
tbl_add_literal(Tbl, ~false, Tbl) :- !.

tbl_add_literal(_, false, closed([])) :- !.
tbl_add_literal(_, ~true, closed([])) :- !.

tbl_add_literal(TblIn, A=B, TblOut) :-
  !,
  ( unifiable(A, B, Bindings) ->
    ( Bindings = [] ->
      % The terms are identical, so this literal is a tautology.
      TblOut = TblIn
    ;
      (
        % This can be made into a contradiction by insisting that any one of
        % the free-variable bindings be in fact un-unifiable.
        member(Binding, Bindings),
        TblOut = closed([Binding])
      ;
        % Or the branch can be left open, and we just do the bindings.
        tbl_apply_var_bindings(TblIn, Bindings, TblOut)
      )
    )
  ;
    % The terms are not unifiable, so this literal is a contradiction.
    TblOut = closed([])
  ).

tbl_add_literal(TblIn, ~(A=B), TblOut) :-
  !,
  ( unifiable(A, B, Bindings) ->
    ( Bindings = [] ->
      % The terms are identical, so this literal is a contradiction.
      TblOut = closed([])
    ;
      (
        % This literal can be made into a contradiction via unification.
        tbl_apply_var_bindings(TblIn, Bindings),
        TblOut = closed([])
      ;
        % Or the branch can be left open by not doing the bindings.
        tbl_add_neqs(TblIn, [A=B], TblOut)
      )
    )
  ;
    % The terms are not unifiable, so this literal is a tautology.
    TblOut = TblIn
  ).

tbl_add_literal(TblIn, ~Lit, TblOut) :-
  !,
  TblIn = tbl(UnExp, TLits, FLitsIn, NEqs, Axs, Necc, Poss, Univ, FVs),
  % Try to produce a contradiction with one of the true literals.
  tbl_add_literal_find_contradiction(TblIn, Lit, TLits, Res),
  ( Res = closed ->
    TblOut = closed([])
  ;
    % Add it to the list of things known to be false, unless we already know.
    ( ismember(Lit, FLitsIn) ->
        FLitsOut = FLitsIn
    ;
        FLitsOut = [Lit|FLitsIn]
    ),
    TblOut = tbl(UnExp, TLits, FLitsOut, NEqs, Axs, Necc, Poss, Univ, FVs)
  ).

tbl_add_literal(TblIn, Lit, TblOut) :-
  !,
  TblIn = tbl(UnExp, TLitsIn, FLits, NEqs, Axs, Necc, Poss, Univ, FVs),
  % Try to produce a contradiction with one of the false literals.
  tbl_add_literal_find_contradiction(TblIn, Lit, FLits, Res),
  ( Res = closed ->
    TblOut = closed([])
  ;
    % Add it to the list of things known to be true, unless we already know.
    ( ismember(Lit, TLitsIn) ->
        TLitsOut = TLitsIn
    ;
        TLitsOut = [Lit|TLitsIn]
    ),
    TblOut = tbl(UnExp, TLitsOut, FLits, NEqs, Axs, Necc, Poss, Univ, FVs)
  ).


%
%  Helper predicate to search for contradictions in a set of complimentary
%  literals.  It first tries to find a member identical to the target,
%  in which case the branch is always closed and no backtracking is required.
%  Otherwise, it tries to find one unifiable with the taret, but allows
%  backtracking over these choices.  If all such choices are backtracked over
%  (or none are found) then the branch remains open.
%

tbl_add_literal_find_contradiction(Tbl, Lit, NLits, Res) :-
  tbl_add_literal_find_contradiction_bindings(Lit, NLits, Bindings),
  ( Bindings = [] ->
    % No possible bindings, so we fail to find any contraditions.
    Res = open
  ;
    sort(Bindings, OrderedBindings), 
    ( OrderedBindings = [[]|_] ->
      % Found a contradiction with no bindings, so no need to backtrack.
      Res = closed
    ;
      % Found a contradiction if we do some backtrackable unification.
      (
        member(B, OrderedBindings),
        tbl_apply_var_bindings(Tbl, B),
        Res = closed
      ;
        Res = open
      )
    )
  ).

tbl_add_literal_find_contradiction_bindings(_, [], []).
tbl_add_literal_find_contradiction_bindings(Lit, [NLit|NLits], Bindings) :-
  ( unifiable(Lit, NLit, B) ->
    Bindings = [B|Bs],
    tbl_add_literal_find_contradiction_bindings(Lit, NLits, Bs)
  ;
    tbl_add_literal_find_contradiction_bindings(Lit, NLits, Bindings)
  ).

%
%  tbl_apply_var_bindings/2
%  tbl_apply_var_bindings/3  -  apply variable bindings and check constraints
%
%  This predicate takes a list of [A=B] pairs makes them unify with occurs
%  check.  It also checks that various proof-search constraints are not
%  violated by the bindings:
%
%    * two free variables generated from the same source formula are never
%      bound to an identical term, as this would be redundant.
%
%    * any declared non-unifiability constrains are not violated. 
%
%  If called with three arguments, this predicate will also remove any
%  non-unifiability constraints that have become tautological and return
%  the updated tableaux state in its third argument.
%

tbl_apply_var_bindings(TblIn, Bindings) :-
  tbl_apply_var_bindings(TblIn, Bindings, _).

tbl_apply_var_bindings(TblIn, [], TblOut) :-
  tbl_check_neqs(TblIn, TblOut).

tbl_apply_var_bindings(TblIn, [A=B|Bindings], TblOut) :-
  unify_with_occurs_check(A, B),
  tbl_apply_var_bindings(TblIn, Bindings, TblOut).

attr_unify_hook(OtherValues, Value) :-
  % This hook gets called when one of our free variables is bound.
  % Veto the binding if it is bound to a previously-used value, since
  % that's redundant for the proof search.
  \+ ismember(Value, OtherValues).



%
%  Helper predicate to check that non-unifiability constraints have
%  not been violated.  It also helps to trim down the list of constraints
%  if some have become tautological.
%

tbl_check_neqs(TblIn, TblOut) :-
  TblIn = tbl(UnExp, TLits, FLits, NEqsIn, Axs, Necc, Poss, Univ, FVs),
  tbl_check_neqs_list(NEqsIn, NEqsOut),
  TblOut = tbl(UnExp, TLits, FLits, NEqsOut, Axs, Necc, Poss, Univ, FVs).

tbl_check_neqs_list([], []).
tbl_check_neqs_list([A=B|NEqsIn], NEqsOut) :-
  ( unifiable(A, B, Bindings) ->
    Bindings \= [],
    NEqsOut = [A=B|NEqsOutRest],
    tbl_check_neqs_list(NEqsIn, NEqsOutRest)
  ;
    tbl_check_neqs_list(NEqsIn, NEqsOut)
  ).

%
%  Test cases for basic prover functionality.
%

:- begin_tests(prover, [sto(rational_trees)]).

test(prop1) :-
  prove(true),
  prove(~false),
  prove(red = red),
  prove(~(red = blue)),
  prove(p | ~p),
  \+ prove(p | q).

test(prop2) :-
  prove([q], p | q).

test(knows1) :-
  prove(knows(ann, p | ~p)),
  \+ prove(knows(ann, p | q)),
  \+ prove(knows(ann, p & ~p)).

test(knows2) :-
  prove([q], knows(ann, p | q)).

test(knows4) :-
  prove(knows(ann, knows(bob, p)) => knows(ann, knows(bob, p | q))),
  \+ prove(knows(ann, knows(bob, p | q)) => knows(ann, knows(bob, p))).

test(knows5) :-
  prove([(p | q)], knows(ann, knows(bob, p | q))).

test(knows6) :-
  prove(knows(ann, knows(bob, p(c) | ~p(c)))).

test(knows7) :-
  prove(knows(ann, p(c)) => knows(ann, ext([X], p(X)))),
  prove(knows(ann, all([X], p(X))) => knows(ann, p(c))).

test(knows12) :-
  prove(knows(ann, knows(bob, p(x))) => ext([X], knows(ann, knows(bob, p(X))))),
  prove(knows(ann, knows(bob, p(x))) => knows(ann, ext([X], knows(bob, p(X))))),
  prove(knows(ann, knows(bob, p(x))) => knows(ann, knows(bob, ext([X], p(X))))).

test(eq1) :-
  prove(all([X], (X=red) => hot(X)) => hot(red)).

:- end_tests(prover).
