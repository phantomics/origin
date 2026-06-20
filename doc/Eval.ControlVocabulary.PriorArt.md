# Control Vocabulary: Prior-Art Evaluation

This document evaluates the control vocabularies of the prior-art technologies
named in `DevPlan.ControlVocabulary.md`. For each, it renders a small subset of
the technology's grammar as Common Lisp forms, grounds the rendition in a shared
Origin scenario, and scores the ergonomics against a rubric drawn from the
DevPlan's design goals. The aim is not to specify Origin's vocabulary but to
learn from each ancestor what to borrow and what to avoid when designing the
control surface for Origin's orbitals.

The evaluation proceeds in installments. **Installment I** covers **SNMP**
(GET/SET over MIBs), the **z/OS `MODIFY` (`F`)** operator command, and **JMX
MBeans**. **Installment II** covers **HTTP safe methods** (RFC 9110),
**GraphQL**, and **NETCONF/YANG** -- the references with declarative and
capability-negotiation ancestry that Installment I's synthesis flagged as the
missing tier. The Method, shared scenario, representativeness caveat, and rubric
below are shared by all installments; each installment then contributes its own
renditions, comparison, and synthesis.

**Date:** 2026-06-17

**Status:** Evaluation. No implementation; the Lisp here is illustrative
sketch, not loadable code. It is exploratory companion material to the
Control Vocabulary development plan.


## Method

Three constraints keep the comparison honest:

1. **One scenario, three vocabularies.** Every rendition expresses the *same*
   handful of operations against the *same* target, so differences are
   differences of vocabulary rather than of example. The target is the
   DevPlan's motivating case: a Lexter terminal-host orbital.

2. **A small subset.** Each technology is reduced to the few verbs and naming
   constructs that carry its essential shape. Transport, security, and
   encoding are out of scope; this is about the *language*, not the wire.

3. **A fixed rubric.** Each rendition is scored against criteria taken
   directly from the DevPlan goals (G1-G8) and open questions (Q5), so the
   three can be compared on common axes.

The illustrative forms assume a hypothetical `origin-control` package; symbol
prefixes (`snmp-`, `modify`, `mbean-`) mark which ancestor's idiom is being
sketched. None of this is wired to Origin's real `start-process` / `status`
protocol -- that mapping is the synthesis at the end.


## The shared scenario

`:term-host` is an `:image` orbital (a dedicated Lexter image) hosting several
`:cooperative` terminal windows, each with a scrollback buffer, a working
directory, a font, and a poll interval. The core wants to perform four
representative operations -- one per archetype the DevPlan cares about:

| Tag | Archetype | Operation | CQS class |
|-----|-----------|-----------|-----------|
| **Q** | query (read) | Read window 2's total buffer lines and pwd; then the same for *all* windows | safe |
| **C-set** | configure (write, no restart) | Set window 2's poll interval to 250 ms | mutating |
| **C-delta** | imperative delta | Open two more windows; close window 2 | mutating |
| **D** | discovery | Ask `:term-host` which verbs / queries / parameters it supports | safe |

These four map onto the DevPlan's proposed universal verbs (`status`,
`configure`, `delta`, `describe`) and onto its open question Q5 (addressing and
selectors -- here, "window 2" versus "all windows"). The motivating sugar the
DevPlan already wrote down is the yardstick:

```lisp
(origin-control:status :term-host :window :all :query '(:total-lines :pwd))
```


## Representativeness: orbital archetypes and the contrast pass

A single shared example correctly controls for example-variance *within* a
comparison -- it is why the three renditions below are comparable at all. It
must not, however, become the basis for *generalizing* the vocabulary's shape.
Lexter is atypical: its sub-objects (windows) are enumerable, stable, and
durable; its queries are discrete attribute reads; it carries rich session
state; it is persistent and interactive; and -- a subtle trap -- its windows
are simultaneously its own domain objects *and* genuine cooperative orbitals,
which blurs "address through to a sub-orbital" with "read a domain attribute."
Many Origin targets (web services, data gateways) share none of this.

The vocabulary should therefore be checked against these axes of variation,
not just the Lexter column:

| Axis | Lexter | Contrasting end |
|------|--------|-----------------|
| Sub-object cardinality | enumerable, stable (windows) | high, ephemeral, churning (connections / requests) |
| Metric nature | discrete attribute read | rate / aggregate / percentile / time-window |
| Statefulness | rich session state (scrollback) | stateless / in-flight-only |
| Lifecycle | persistent, interactive | finite (batch) or long-running headless |
| Declarative shape | collection of UI objects | configuration tree (ports, routes, pool size) |
| Sub-object ontology | domain object *and* orbital (conflated) | plainly not an orbital (a connection) |
| Control cadence | human-paced, low-frequency | automated, high-frequency, backpressure |

Two contrasting archetypes (both named in the DevPlan), plus one optional, will
serve as the stress cases: an **HTTP-server orbital** (high-cardinality
ephemeral connections, rate/aggregate metrics, config-heavy declarative state,
drain-on-stop, readiness != liveness); a **data orbital** (DB / S3 gateway:
connection pool, cache hit-rate, backpressure, expensive backend-touching
reads, no UI); and optionally a **batch / ETL worker** (finite lifecycle,
progress, `:transient` restart semantics).

**Adopted methodology.** Future evaluations keep Lexter as the shared
comparison control but add a short *contrast pass* against the HTTP-server
(and/or data) orbital to surface what Lexter hides. The
sub-orbital-versus-domain-object conflation (axis 6) is flagged as the specific
addressing hazard to watch when designing the selector grammar (open Q5).


## The rubric

Each rendition is scored on:

- **G1 Structured** -- are requests and responses data with known shape, or
  strings to be scraped?
- **G2 Data-not-code** -- is the message a datum dispatched on, with a bounded
  (closed) surface, rather than a form evaluated?
- **G3 CQS** -- does the vocabulary itself distinguish safe reads from
  mutations?
- **G4 Two-tier** -- small universal verb set carrying a per-target typed
  sub-vocabulary?
- **G5 Self-describing** -- can a target report its own verbs/queries/schema
  (`describe`)?
- **G6 Declarative/Δ** -- declarative desired-state and/or explicit additive
  /subtractive delta?
- **Q5 Addressing** -- how are targets and sub-targets (`:window 2`,
  `:window :all`) named?
- **Steal / Reject** -- the one-line lesson for Origin.


---

# Installment I -- SNMP, z/OS MODIFY, JMX

The first three references share a two-tier, command/query-separated shape and
predate the declarative-reconciliation idea; they are evaluated below against
the shared Lexter scenario.


## Rendition 1 -- SNMP (GET / GETNEXT / GETBULK / SET over a MIB)

SNMP's model is a *managed object* tree. Every leaf has an **OID** (a path of
integers), an **SMI type** (`INTEGER`, `Counter32`, `Gauge32`, `OCTET STRING`,
`TimeTicks`, ...), and a **MAX-ACCESS** level (`not-accessible`,
`accessible-for-notify`, `read-only`, `read-write`, `read-create`). The
protocol verbs are deliberately tiny: `get`, `get-next`, `get-bulk`, `set`,
plus the agent-initiated `trap`/`inform`. Tabular data (e.g. one row per
window) is read by *walking* with `get-next`/`get-bulk` because there is no
"give me the whole table" verb.

### The MIB as a Lisp datum

A MIB is a schema. Rendered as Lisp, it is a tree of typed, access-tagged
object definitions -- exactly the kind of self-description SNMP keeps *out of
band* (in MIB files shipped separately) rather than queryable from the agent:

```lisp
(define-mib :lexter
  ;; scalar objects under the host
  (:host
   (:window-count   :oid 1  :type :gauge32   :access :read-only))
  ;; a conceptual table: one conceptual row per window, INDEXed by window id
  (:window-table
   (:oid 2)
   (:index :window-id)
   (:columns
    (:window-id     :oid 1  :type :integer32 :access :not-accessible) ; index
    (:total-lines   :oid 2  :type :gauge32   :access :read-only)
    (:pwd           :oid 3  :type :octet-str :access :read-only)
    (:poll-interval :oid 4  :type :integer32 :access :read-write)
    (:font          :oid 5  :type :octet-str :access :read-write))))
```

A leaf instance is addressed by the column OID plus the row index. Symbolic
names resolve to numeric OIDs; the wire form of `:total-lines` of window 2 is
the dotted path `…lexter.windowTable.totalLines.2` -> `…2.2.2`.

### The four operations

```lisp
;; Q -- read window 2's total-lines and pwd (two var-binds, one GET)
(snmp-get :term-host '((:lexter :window-table :total-lines 2)
                       (:lexter :window-table :pwd         2)))
;; => ((#oid(:lexter :window-table :total-lines 2) . 1843)
;;     (#oid(:lexter :window-table :pwd         2) . "/home/user/src"))

;; Q (fan-out) -- "all windows" is not a verb; it is a WALK of the column
(snmp-walk :term-host '(:lexter :window-table :total-lines))
;; => ((… :total-lines 1) . 920) ((… :total-lines 2) . 1843) ((… :total-lines 7) . 12)

;; Q (efficient fan-out) -- GETBULK: 0 non-repeaters, up to 50 repetitions
(snmp-get-bulk :term-host
               :non-repeaters 0 :max-repetitions 50
               '((:lexter :window-table :total-lines)
                 (:lexter :window-table :pwd)))

;; C-set -- write a read-write leaf
(snmp-set :term-host '(((:lexter :window-table :poll-interval 2) . 250)))
;; => :no-error    ; or e.g. :not-writable, :wrong-type, :no-such-name

;; C-delta -- NOT NATURAL. SNMP has no "open window" verb. The RowStatus
;; idiom fakes creation/deletion by SETting a magic status column:
(snmp-set :term-host '(((:lexter :window-table :row-status 8) . :create-and-go)))
(snmp-set :term-host '(((:lexter :window-table :row-status 2) . :destroy)))

;; D -- discovery: there is no on-line describe. You ship the MIB file and
;; the manager loads it out of band:
(load-mib #p"LEXTER-MIB.lisp")     ; not a request to the agent at all
```

### Traps as the `watch` direction

The one place SNMP pushes rather than polls is the trap/inform: the agent
emits a notification var-bind list when something happens. This is the
ancestor of the DevPlan's `watch`/`subscribe`:

```lisp
(define-trap :window-closed
  :enterprise (:lexter)
  :var-binds ((:lexter :window-table :window-id)))
```

### Ergonomics

- **G1 Structured: strong.** A response is a list of `(oid . typed-value)`
  var-binds, never free text. Errors are an enumerated `error-status`
  (`no-such-name`, `not-writable`, `wrong-type`, ...) plus an `error-index`
  pointing at the offending var-bind -- a structured error envelope decades
  before the DevPlan asked for one (open Q2).
- **G2 Data-not-code: strong.** An OID is pure data; the agent dispatches on
  it. The surface is closed by construction -- you can only name objects the
  MIB defines. This is precisely the DevPlan's "datum the receiver reads and
  dispatches on, never a form it evaluates."
- **G3 CQS: strong, and *typed into the schema*.** MAX-ACCESS is the model's
  best idea for Origin: read/write capability is a property of each object,
  declared once, ordered (`read-only` < `read-write` < `read-create`), and
  enforced uniformly by the verb (`set` on a `read-only` leaf is
  `not-writable`). This is CQS pushed down to the leaf, finer-grained than the
  DevPlan's per-*verb* safe/mutating split.
- **G4 Two-tier: strong, and the cleanest of the three.** Four universal verbs
  (`get`/`get-next`/`get-bulk`/`set`) carry an unbounded per-device MIB. This
  *is* the "small universal outer verb + target-specific inner language" shape
  the DevPlan names. Origin's `(status … :query (…))` is GET with named
  columns.
- **G5 Self-describing: weak -- the cautionary lesson.** The agent cannot tell
  you its own schema; MIBs are shipped out of band and loaded by the manager.
  This is exactly what the DevPlan rejects by putting `describe` in v1. SNMP
  shows the *cost* of out-of-band schema: version skew between the MIB you
  loaded and the agent you're talking to, with no negotiation.
- **G6 Declarative/Δ: weak.** No declarative desired-state; creation/deletion
  is bolted on through the `RowStatus` convention (`createAndGo`, `destroy`) --
  a write to a magic column standing in for a real lifecycle verb. The
  C-delta rendition above is awkward precisely because SNMP has no delta.
- **Q5 Addressing: the central lesson, good and bad.** The OID *grammar* is
  excellent: a hierarchical, namespaced path with a uniform table-walk for
  "all rows." But the OID *surface form* -- dotted integers -- is the
  canonical ergonomic disaster; it is only bearable because MIBs map symbols
  onto numbers. Origin gets the grammar for free (S-expression paths like
  `(:window :all :total-lines)`) and pays none of the dotted-integer cost.

**Steal:** the namespaced typed-leaf path; per-leaf access level (MAX-ACCESS)
as CQS-in-the-schema; structured `error-status` + `error-index`; table-walk as
the `:all` fan-out; traps as the `watch` seed. **Reject:** numeric OIDs;
out-of-band, unqueryable schema; lifecycle-by-magic-column.


---

## Rendition 2 -- z/OS `MODIFY` (`F jobname,command`)

The mainframe operator console offers a tiny set of *universal* commands that
apply to any started task: `START` (`S`), `STOP` (`P`), `CANCEL` (`C`), and
above all `MODIFY` (`F`). The form is:

```
F jobname,command-text
```

`MODIFY` is a pure envelope: the system routes `command-text` to the named
subsystem and the subsystem parses it however it likes. CICS receives
`CEMT`-style text, Db2 receives `-` commands, a home-grown server receives
whatever its author coded. The outer verb is universal and structured; the
**inner command is an unstructured, per-subsystem string**.

### The grammar, rendered two ways

The honest rendition of native `MODIFY` keeps the inner command as text,
because that is what it is:

```lisp
;; The universal lifecycle verbs -- structured, tiny, target-agnostic
(start  :term-host)                 ; S TERMHOST
(stop   :term-host)                 ; P TERMHOST
(cancel :term-host)                 ; C TERMHOST   (force)

;; Q  -- MODIFY carrying a subsystem display sub-command, AS TEXT
(modify :term-host "DISPLAY WINDOW=2,FIELDS=(LINES,PWD)")
;; <- reply is also text, written to the console / job log:
;;    "TERMHOST: WINDOW 2 LINES=1843 PWD=/home/user/src"

;; C-set
(modify :term-host "SET WINDOW=2,POLL=250")

;; C-delta -- MODIFY's strength: the sub-language can say anything
(modify :term-host "OPEN COUNT=2")
(modify :term-host "CLOSE WINDOW=2")

;; D  -- by convention a HELP/DISPLAY sub-command, returning TEXT
(modify :term-host "DISPLAY COMMANDS")
;; -> "VALID: DISPLAY SET OPEN CLOSE HELP"   (prose, not a schema)
```

Now the same operations as Origin *would* render them -- the outer verb
preserved, the inner string promoted to a datum:

```lisp
;; Q
(modify :term-host '(:display :window 2 :fields (:lines :pwd)))
;; => (:window 2 :lines 1843 :pwd "/home/user/src")

;; C-set
(modify :term-host '(:set :window 2 :poll-interval 250))

;; C-delta
(modify :term-host '(:open :count 2))
(modify :term-host '(:close :window 2))

;; D
(modify :term-host '(:describe))
;; => (:commands ((:display …) (:set …) (:open …) (:close …)))
```

The diff between the two blocks *is* the DevPlan thesis in miniature: same
two-tier shape, but one inner language is a string to be scraped and the other
is a datum to be dispatched on.

### Ergonomics

- **G1 Structured: outer yes, inner no.** `F jobname,…` is structured framing,
  but the command text and *every reply* are unstructured console messages.
  Tooling must regex `WINDOW 2 LINES=1843` out of prose -- the precise failure
  the DevPlan opens against ("status is a plist, not a log line"). This is the
  best illustration in all of prior art of *why* G1 exists.
- **G2 Data-not-code: surface is closed, but opaquely.** The subsystem parses
  text, so it is not arbitrary eval -- the surface is bounded by the parser.
  But the boundary is invisible and per-subsystem; there is no datum to
  inspect, only a string to hand over and hope.
- **G3 CQS: by convention only.** Nothing distinguishes `DISPLAY` (safe) from
  `SET` (mutating) except operator knowledge and naming habit. The vocabulary
  carries no safe/mutating bit; auditing means parsing the command text.
- **G4 Two-tier: the archetype -- and Origin's closest operational twin.**
  This is the purest "universal operator verb carrying a target-specific
  sub-language" in computing. `MODIFY` is `signal`/`configure` with the inner
  language fully delegated to the target. The DevPlan is right to name it the
  closest twin: Origin keeps this exact shape and only changes the inner
  medium from text to S-expressions.
- **G5 Self-describing: by convention only.** `DISPLAY COMMANDS` / `HELP`
  exists by habit, returns prose, and is not machine-consumable. No schema, no
  parameter types -- a UI cannot be generated from it.
- **G6 Declarative/Δ: imperative only, but *naturally* delta.** `OPEN COUNT=2`
  and `CLOSE WINDOW=2` show that an imperative sub-language expresses
  add/subtract effortlessly -- MODIFY is far better at C-delta than SNMP. What
  it lacks is any declarative desired-state notion and any idempotence
  guarantee; re-issuing `OPEN COUNT=2` opens two *more* windows.
- **Q5 Addressing: two-level and coarse.** `jobname` names the target; the
  sub-target (`WINDOW=2`) lives inside the opaque command text, so there is no
  uniform selector grammar -- each subsystem invents `WINDOW=2` vs `W2` vs
  positional. Origin's structured inner form fixes this by making the selector
  part of the datum.

**Steal:** the universal-verb-carries-sub-language envelope (the core idea
behind `signal` and the per-orbital sub-vocabularies); the tiny universal
lifecycle set (`start`/`stop`/`cancel`); imperative delta as a first-class
expression. **Reject:** unstructured text as the inner language and the reply;
CQS and discovery left to operator lore; no idempotence.


---

## Rendition 3 -- JMX MBeans (attributes / operations / notifications + MBeanInfo)

JMX models a managed resource as an **MBean** registered under a structured
**ObjectName** (`domain:key1=value1,key2=value2,…`). An MBean exposes three
kinds of feature, and the split is the whole point:

- **Attributes** -- named, typed values, each `isReadable` / `isWritable`,
  accessed by `getAttribute` / `setAttribute`. This is the read/configure
  surface.
- **Operations** -- named methods invoked by `invoke`, each tagged with an
  **impact**: `INFO` (read-like), `ACTION` (write-like), `ACTION_INFO` (both),
  or `UNKNOWN`. This is the command surface.
- **Notifications** -- the push channel (`watch`).

And critically, every MBean answers `getMBeanInfo`, returning an **MBeanInfo**:
class name, description, `MBeanAttributeInfo[]`, `MBeanOperationInfo[]`,
`MBeanNotificationInfo[]`, `MBeanConstructorInfo[]`. The management interface
is queryable *from the bean itself*, at runtime -- the antithesis of SNMP's
out-of-band MIB.

### The MBean as a Lisp datum

```lisp
;; A window is an MBean named by a structured ObjectName.
(register-mbean '(:domain :lexter :type :window :id 2)
  :attributes
  '((:total-lines   :type :integer :readable t :writable nil)
    (:pwd           :type :string  :readable t :writable nil)
    (:poll-interval :type :integer :readable t :writable t)
    (:font          :type :string  :readable t :writable t))
  :operations
  '((:clear-scrollback :impact :action :returns :void :signature ()))
  :notifications
  '((:window-closed :fields (:id))))

;; The host itself is an MBean that owns window lifecycle.
(register-mbean '(:domain :lexter :type :host)
  :operations
  '((:open-windows :impact :action :returns (:list :integer)
                   :signature ((:count :integer)))
    (:close-window :impact :action :returns :void
                   :signature ((:id :integer)))))
```

### The four operations

```lisp
;; Q -- read attributes off a precisely named bean
(mbean-get-attributes '(:lexter :type :window :id 2) '(:total-lines :pwd))
;; => (:total-lines 1843 :pwd "/home/user/src")

;; Q (fan-out) -- query the name SPACE with a pattern, then read each
(mbean-query '(:lexter :type :window :id :*))     ; ObjectName pattern
;; => (#on(:lexter :type :window :id 1) #on(… :id 2) #on(… :id 7))
;; (then map mbean-get-attributes over the set)

;; C-set -- write a writable attribute
(mbean-set-attribute '(:lexter :type :window :id 2) :poll-interval 250)

;; C-delta -- invoke ACTION operations on the host bean
(mbean-invoke '(:lexter :type :host) :open-windows '((:count 2)))  ; => (8 9)
(mbean-invoke '(:lexter :type :host) :close-window '((:id 2)))

;; D -- the model for `describe`: ask the bean for its own interface
(mbean-info '(:lexter :type :window :id 2))
;; => (:class-name "LexterWindow"
;;     :attributes ((:total-lines :type :integer :readable t :writable nil) …)
;;     :operations ((:clear-scrollback :impact :action …))
;;     :notifications ((:window-closed :fields (:id))))
```

### Ergonomics

- **G1 Structured: strong.** Attribute values are typed; `MBeanInfo` is a
  structured record. No scraping. (JMX's weakness is elsewhere: rich return
  types lean on Java serialization -- a non-issue for Origin, whose values are
  already S-expressions.)
- **G2 Data-not-code: strong, with a caveat.** Names, attributes, and
  operation invocations are data dispatched by the MBeanServer; the surface is
  closed to what the bean registered. The caveat: `invoke` with a free
  operation name plus a `signature` array is the most code-like of the three
  models -- it is reflective method dispatch. Origin should keep operations a
  *registered, discoverable* set (which JMX does) and never a reflective
  call-anything channel.
- **G3 CQS: strong, and at the protocol level -- the best of the three.** The
  attribute/operation split is structural: reads go through
  `getAttribute`, writes through `setAttribute`, effects through `invoke`, and
  each attribute carries `isWritable` while each operation carries its
  `impact` (`INFO`/`ACTION`/`ACTION_INFO`). This is the GraphQL query/mutation
  split avant la lettre and the richest CQS signal available to a UI: it can
  grey out read-only attributes and flag mutating operations from metadata
  alone.
- **G4 Two-tier: strong, expressed as kinds rather than verbs.** The universal
  surface is `{getAttribute, setAttribute, invoke, getMBeanInfo,
  addNotificationListener}`; the per-type sub-vocabulary is the bean's
  registered attributes and operations. Slightly different framing from SNMP's
  (kinds-of-feature rather than verbs-over-a-tree) but the same two-tier
  result.
- **G5 Self-describing: strong -- the direct ancestor of `describe`.**
  `MBeanInfo` is exactly what the DevPlan's `describe` must return: the verbs
  (operations), the queries (attributes), their types, their read/write
  status, and their human descriptions, *from the live target*. A management
  console renders itself from `MBeanInfo`; the DevPlan's "Lexter admin surface
  renders from discovered metadata" is the same move. This is the single
  closest match to a settled Origin decision.
- **G6 Declarative/Δ: weak.** Like the others, JMX is imperative: no
  declarative desired-state, no reconciliation. Delta is expressible only as
  ACTION operations (`open-windows`, `close-window`) -- workable, like MODIFY,
  but not idempotent and not declarative.
- **Q5 Addressing: the best naming model of the three.** The ObjectName --
  a domain plus an unordered key/value property list, with pattern matching
  (`:id :*`) over the name space -- is structured, self-documenting, and
  fans out cleanly to "all windows" via a query pattern rather than SNMP's
  walk or MODIFY's opaque `WINDOW=2`. This maps almost directly onto Origin's
  selector need from open question Q5: `(:lexter :type :window :id 2)` is a
  selector plist and `(… :id :*)` is `:all`.

**Steal:** `MBeanInfo` -> `describe` wholesale (verbs + queries + types +
read/write + descriptions, from the live target); the attribute/operation
(read vs effect) split as protocol-level CQS, with `isWritable` and operation
`impact` as the per-feature safe/mutating tags; ObjectName's domain +
key/value selector with pattern fan-out -> Origin's selector grammar.
**Reject:** reflective `invoke(name, params, signature)` as an open-ended
channel -- keep operations registered and discovered, not free-form;
Java-serialization-shaped return values (irrelevant to an S-expression
substrate anyway).


---

## Comparison -- Installment I

| Axis | SNMP | z/OS MODIFY | JMX MBeans |
|------|------|-------------|------------|
| **G1 Structured** | Strong (typed var-binds; enumerated errors) | Outer only; inner + replies are prose | Strong (typed attrs; MBeanInfo record) |
| **G2 Data-not-code** | Strong (OID is data; closed by MIB) | Closed but opaque (text parsed per subsystem) | Strong; `invoke` is the most code-like point |
| **G3 CQS** | Strong -- per-leaf MAX-ACCESS (in schema) | Convention only (operator lore) | Strong -- attr/op split + `isWritable`/`impact` (protocol) |
| **G4 Two-tier** | Strong -- 4 verbs over a MIB tree | Archetype -- `F` carries a sub-language | Strong -- feature-kinds over registered beans |
| **G5 Self-describing** | Weak -- MIB shipped out of band | Weak -- `HELP` is prose | Strong -- `MBeanInfo` from the live bean |
| **G6 Declarative/Δ** | Weak -- create/destroy via RowStatus hack | Imperative; natural delta, no idempotence | Imperative; delta via ACTION ops, no idempotence |
| **Q5 Addressing** | Namespaced path; great grammar, awful dotted form | Two-level + opaque inner selector | Best -- domain + key/value ObjectName, pattern fan-out |
| **One-line** | The two-tier + typed-CQS schema model, minus the digits and the out-of-band MIB | The universal-verb envelope, minus the text | The `describe` and selector model, plus protocol CQS |


## Synthesis for Origin -- Installment I

The three ancestors are strikingly complementary -- each is strongest exactly
where the others are weak, and Origin can take the best axis from each:

1. **Take JMX's `MBeanInfo` as the template for `describe` (G5).** It is the
   only one of the three with live, machine-consumable self-description, and it
   already carries everything the DevPlan's `describe` must: operations
   (verbs), attributes (queries), their types, their read/write status, and
   descriptions. The "Lexter admin renders from discovered metadata" goal is
   `getMBeanInfo` by another name. This is the firmest borrowing.

2. **Take SNMP's typed, access-tagged leaf as the model for the sub-vocabulary
   schema (G3, G4).** MAX-ACCESS shows CQS belongs *in the schema*, per
   query/parameter, not only per verb -- finer than the DevPlan's current
   per-verb safe/mutating split and worth considering: each `:query` selector
   and each `configure` parameter could carry its own access level, with
   discovery deriving the verb-level classification from the leaves. SNMP's
   enumerated `error-status` + `error-index` is also a ready model for the
   response/partial-error envelope (open Q2), especially for `:window :all`
   fan-out where some rows succeed and some fail.

3. **Take MODIFY's envelope as the shape of `signal` and the typed
   sub-vocabularies (G4).** A small universal outer verb carrying a
   target-specific inner language is Origin's whole architecture; MODIFY is the
   proof it works operationally at scale. Origin's single change -- the one the
   DevPlan is built on -- is to make the inner language an S-expression *datum*
   (JMX-structured, SNMP-typed) instead of MODIFY's scraped text. The
   side-by-side MODIFY rendition above is the clearest one-screen argument for
   the project.

4. **Synthesize the addressing grammar from SNMP + JMX (Q5).** Take SNMP's
   hierarchical path grammar and its uniform "walk = all" fan-out, but express
   it in JMX's structured key/value selector form rather than dotted integers:
   `(:window 2)` for one, `(:window :all)` (or a `(:window :*)` pattern) for
   the set. The DevPlan's `:window :all :query (:total-lines :pwd)` is already
   precisely this hybrid -- a JMX-shaped selector over an SNMP-shaped column
   query.

5. **Note the shared gap: declarative desired-state (G6).** *None* of the
   three is declarative or idempotent; all express change imperatively, and
   SNMP's RowStatus hack shows how badly a query/get model handles lifecycle.
   This is where Origin's plan deliberately departs from all three prior art
   here -- the declarative `apply` / desired-orbit reconciler has no ancestor
   in this trio and should be sought instead in the later references
   (Kubernetes, NETCONF candidate/running datastores). The imperative `delta`
   verb, by contrast, has good ancestry in MODIFY's `OPEN COUNT=2` /
   `CLOSE WINDOW=2`.

In short: **MODIFY gives Origin the envelope, JMX gives it `describe` and the
selector, SNMP gives it the typed CQS-in-schema and the error model -- and the
declarative tier must come from elsewhere.** The next evaluation installment
should take up the references that *do* have declarative ancestry (Kubernetes,
NETCONF/YANG) together with the CQS-at-the-protocol references already partly
seen here (GraphQL, HTTP safe methods).


---

# Installment II -- HTTP Safe Methods, GraphQL, NETCONF/YANG

Installment I closed on a gap: its three ancestors were imperative, with no
declarative desired-state and no version negotiation. This installment takes up
the three references that supply exactly those missing pieces. It reuses the
rubric and the shared Lexter scenario unchanged, and -- following the
*contrast pass* adopted in "Representativeness" above -- adds a second,
deliberately un-Lexter-like target: an HTTP-server orbital. These three
technologies are precisely the ones that Lexter's terminal model under-exercises
(aggregate metrics, configuration trees, high-cardinality collections,
declarative convergence), so the contrast pass does real work here rather than
merely restating the Lexter result.


## The contrast scenario: an HTTP-server orbital

`:web` is an `:image` orbital running an HTTP server. Where `:term-host` has a
small set of durable, enumerable windows, `:web` has the opposite shape along
every axis from the representativeness table: a churning population of ephemeral
connections, metrics that are rates and percentiles rather than discrete reads,
a configuration *tree* (listen ports, a route table, a worker pool, TLS) rather
than a collection of UI objects, and -- crucially -- routes that are
configuration data, **not** managed orbitals. The same four archetypes, plus the
two the web case forces into view:

| Tag | Archetype | Lexter (`:term-host`) | Web (`:web`) |
|-----|-----------|-----------------------|--------------|
| **Q** | query (read) | window 2's lines + pwd | request-rate, p99 latency, live connections (aggregates) |
| **C-set** | configure | window 2 poll interval | worker-pool size; a route's rate limit |
| **C-delta** | delta | open/close windows | add/remove a route (config collection, not orbitals) |
| **D** | discovery | supported verbs/queries | supported queries/config keys |
| **A** | declarative apply | (Lexter had none) | the whole desired config: ports + routes + pool + TLS |
| **R** | readiness/drain | (n/a) | drain connections; ready != alive |

Archetypes **A** and **R** are the ones Lexter could not surface; they are where
this installment's three references earn their place.


## Rendition 4 -- HTTP Safe Methods (RFC 9110)

HTTP is not a control vocabulary so much as a *method taxonomy*, and that
taxonomy is the borrowable part. RFC 9110 (which obsoletes the RFC 7231 the
DevPlan cites) classifies methods on **two orthogonal axes**: *safe* (GET, HEAD,
OPTIONS, TRACE -- no observable mutation) and *idempotent* (GET, HEAD, PUT,
DELETE, OPTIONS, TRACE -- repeating yields the same effect). POST is neither.
PUT and DELETE are idempotent but not safe. Two axes, not one -- and the spec is
explicit that safety is *a promise to the client, not something the server
enforces*: "a client can expect the resource to avoid actions that are unsafe."
That is exactly the DevPlan's open-question Q1 stance ("safe by construction and
by contract"), with HTTP as decades-long proof the contract is workable.

```lisp
;; Methods as verbs over a resource path. Lexter and web, same tiny verb set:
;; Q (safe, idempotent) -- GET. The resource differs; the verb does not.
(http-get '(:term-host :window 2) :select '(:total-lines :pwd))
(http-get '(:web :metrics)        :select '(:request-rate :p99-latency :connections))

;; HEAD (safe) -- liveness/existence without the body (a cheap readiness probe)
(http-head '(:web :health))                       ; 200 ready / 503 not-ready

;; C-set / A -- PUT is idempotent: PUT the full desired state of a resource.
;; Re-issuing changes nothing further -- this is declarative-by-method.
(http-put '(:web :config :worker-pool) '(:size 16))
(http-put '(:web :config) '(:listen (8080 8443) :pool (:size 16) :tls :on))  ; whole-config apply

;; C-delta -- POST is NOT idempotent: each call appends another route.
(http-post '(:web :routes) '(:path "/v2/orders" :handler :orders-v2))
;; DELETE is idempotent: deleting an absent route still ends "absent".
(http-delete '(:web :routes "/v1/orders"))

;; Optimistic concurrency: only mutate if unchanged since I last observed it.
(http-get '(:web :config :worker-pool))           ; => 200, ETag "etag-3f2a"
(http-put '(:web :config :worker-pool) '(:size 16) :if-match "etag-3f2a")
;; => 412 Precondition Failed if it moved underneath me

;; D -- OPTIONS reports which methods a resource allows (a thin describe)
(http-options '(:web :routes "/v2/orders"))        ; => (:allow (:get :put :delete))
```

### Ergonomics

- **G1 Structured: the taxonomy yes, the wire no.** HTTP's headers are textual,
  but what Origin steals is the *classification*, not the encoding. Responses
  carry status classes (2xx/4xx/5xx) and, notably, **206 Partial Content** -- a
  ready model for the partial result of a `:window :all` / multi-route fan-out
  (open Q2), and **304 Not Modified** for cheap revalidation.
- **G2 Data-not-code: strong.** A handful of methods over data-shaped resource
  paths; nothing is evaluated.
- **G3 CQS: the canonical source, and richer than the DevPlan's current binary.**
  HTTP separates *two* axes -- safe-vs-unsafe and idempotent-vs-not -- where the
  DevPlan currently has one (safe-vs-mutating). The second axis is not
  decoration: it is precisely what distinguishes a declarative idempotent
  `apply`/`configure` (PUT-like) from a non-idempotent `delta` (POST-like).
  Origin should classify each verb on both axes.
- **G4 Two-tier: yes.** Universal methods; per-resource representation and
  allowed-method set.
- **G5 Self-describing: weak-to-moderate.** OPTIONS + the `Allow` header is a
  per-resource capability probe, but it lists only *which* methods are allowed,
  not the *schema* of their parameters -- weaker than `MBeanInfo`. `Accept` /
  `Vary` content negotiation is, however, a seed for representation/version
  negotiation.
- **G6 Declarative/Δ: the first in the whole survey to carry it natively.** PUT
  (idempotent, declarative "make it be this") versus POST (non-idempotent,
  additive "do this") *is* the DevPlan's "declarative default + imperative
  delta," expressed as method semantics rather than two bespoke verbs. This is
  the key find: the distinction Origin wants already has a crisp, battle-tested
  formalization.
- **Q5 Addressing: path hierarchy + conditional preconditions.** The URI path is
  a selector path; **ETag + If-Match** adds an addressing dimension the first
  trio lacked -- "this *version* of this resource" -- giving optimistic
  concurrency for `configure`/`apply` and a concrete seed for vocabulary
  versioning (open Q7).
- **Contrast-pass note.** GET serving `(:web :metrics)` shows the same safe verb
  answering a *rate/aggregate* query, not an object read -- the metric-nature
  axis Lexter hid. HEAD on `(:web :health)` and 503 surface the
  **readiness != liveness** distinction (archetype R) that the terminal model
  never raised.

**Steal:** the two-axis classification (safe? x idempotent?) as the model for
tagging every Origin verb, directly grounding declarative (idempotent) vs delta
(non-idempotent); the "safe = contract, not enforcement" stance (Q1);
ETag/If-Match conditional requests for optimistic-concurrency `configure` and as
a versioning seed (Q7); 206/partial + status classes for the response envelope
(Q2); OPTIONS as a cheap capability probe. **Reject:** textual headers and the
wire format; literal REST resource-orientation (Origin is verb + selector, not
pure resources); statelessness as dogma (Origin's connections are deliberately
stateful sessions).


## Rendition 5 -- GraphQL (query / mutation / subscription + introspection)

GraphQL's contribution is the idea that **the client declares the exact shape of
the data it wants** and the response mirrors that shape -- eliminating both
over- and under-fetching -- over a strongly typed, *introspectable* schema, with
a hard split between `query` (read), `mutation` (write), and `subscription`
(stream).

```lisp
;; Q -- a selection set: ask for exactly these fields; response mirrors the request
(gql-query '(:term-host
             (:window (:id 2)
                      :total-lines :pwd
                      (:cursor :line :col))))
;; => (:window (:id 2 :total-lines 1843 :pwd "/home/user/src"
;;              :cursor (:line 40 :col 3)))

;; Web -- a nested aggregate selection retrieved in ONE round trip (no N+1),
;; with field ARGUMENTS doing filtering / top-N -- the high-cardinality answer
(gql-query '(:web
             (:metrics :request-rate :p99-latency)
             (:routes (:top 3 :by :latency) :path :p99 :hits)))

;; "all windows" is a list-returning field; the client still picks the columns
(gql-query '(:term-host (:windows :all :id :total-lines)))

;; C-set / C-delta -- mutations are the write half; they run serially
(gql-mutation '(:web (:set-worker-pool (:size 16) :size)))         ; returns new size
(gql-mutation '(:web (:add-route (:path "/v2/orders" :handler :orders-v2) :path)))

;; watch -- subscription streams events
(gql-subscribe '(:web (:events :on (:route-saturated) :path :rate)))

;; D -- introspection is itself a query, in the same language
(gql-query '(:term-host (:__schema (:queries :name :args :type)
                                   (:mutations :name :args))))
```

### Ergonomics

- **G1 Structured: strong on both ends.** Request and response are both
  structured, and the response shape is the request shape -- no scraping, no
  guessing which fields come back.
- **G2 Data-not-code: strong, with one caution.** A query is a selection-set
  datum dispatched against a schema; it is bounded to declared fields. The
  caution is depth: arbitrary nesting and aliasing can be abused, so Origin
  should bound query depth/cost (a real GraphQL operational lesson).
- **G3 CQS: strong, at the protocol level.** query / mutation / subscription is a
  three-way split -- safe / mutating / watch -- with queries parallelizable and
  mutations serialized. It is JMX's attribute/operation split generalized and
  given a streaming third arm.
- **G4 Two-tier: yes, cleanly.** The three operation kinds are universal; the
  fields and types are the per-orbital sub-vocabulary -- and the field selection
  *is* the DevPlan's typed `:query` selector list, realized exactly.
- **G5 Self-describing: the strongest model seen.** Introspection (`__schema`,
  `__type`) is reachable *through the same query language* as everything else --
  not a side API like `MBeanInfo` or a separate `<hello>`. A client discovers
  capabilities with the very mechanism it uses for data. This is the cleanest
  possible realization of `describe`.
- **G6 Declarative/Δ: partial, and in a different sense.** GraphQL is
  request/response, not desired-state reconciliation; its mutations are
  imperative. It *is* declarative about the **shape of data requested**, but it
  offers no `apply`/converge. So it strengthens the query tier, not the
  lifecycle tier.
- **Q5 Addressing: best for high cardinality.** Field arguments
  (`(:window (:id 2))`, `(:routes (:top 3 :by :latency))`) are selectors that
  also filter, paginate, and rank -- which is exactly what the web orbital's
  ephemeral, high-cardinality populations need and what SNMP's walk and JMX's
  pattern could not express. The contrast pass makes this visible: Lexter's
  handful of windows never needed `:top 3 :by :latency`.

**Steal:** the selection set as the realized `:query` model (client picks the
fields; response mirrors the request -- the DevPlan's "request exactly the
fields you want"); introspection-through-the-query-language as the cleanest
`describe`; query/mutation/subscription as safe/mutating/watch; field arguments
for filtering / top-N / pagination (the high-cardinality answer); the
data-plus-errors response (partial success, open Q2). **Reject:** the full SDL
type-system ceremony for a CL-native substrate; unbounded query depth/cost
without limits; HTTP-transport assumptions baked into the model.


## Rendition 6 -- NETCONF/YANG (datastores, edit-config, commit, capabilities)

NETCONF is the declarative-tier ancestor the DevPlan explicitly cites for
"candidate versus running datastores -- a model for restart-with-staged-state."
Its model: separate **datastores** (`<running>` -- the live config; `<candidate>`
-- an editable scratch copy; `<startup>` -- boot config), an `<edit-config>`
whose nodes carry a per-node **operation** (`merge` (default), `replace`,
`create`, `delete`, `remove`), an atomic **`<commit>`** (optionally a
*confirmed-commit* that auto-rolls-back unless reconfirmed), `<validate>`,
`<discard-changes>`, a config-vs-state-data distinction (`<get-config>` reads
only configuration; `<get>` reads configuration plus observed state), and a
**capability exchange** via `<hello>` at session start.

```lisp
;; config vs state -- two different reads. get-config: what I declared.
;; get: what is actually happening (read-only operational state).
(nc-get-config :web :running :filter '(:routes))      ; declared route table
(nc-get        :web          :filter '(:metrics))     ; observed rates (state data)

;; Declarative apply against a CANDIDATE, validated, then committed atomically.
(nc-edit-config :web :candidate
  '((:config (:worker-pool (:size 16)))
    (:routes (:route (:@operation :replace)           ; replace this subtree
                     (:path "/v2/orders") (:handler :orders-v2)))))
(nc-validate :web :candidate)                         ; check before it goes live
(nc-commit   :web)                                    ; running <- candidate, atomic
;; ...or abandon the staged edit entirely:
(nc-discard-changes :web)

;; Per-node operations express DELTA inside a declarative edit -- one mechanism
;; spanning both: :merge / :replace (declarative) and :create / :delete / :remove (delta).
(nc-edit-config :web :candidate
  '((:routes (:route (:@operation :delete) (:path "/v1/orders")))))

;; Confirmed commit: apply now, but auto-revert in 30s unless reconfirmed --
;; the safety net for a reconfigure that might sever the core's own control link.
(nc-commit :web :confirmed t :timeout 30)
(nc-commit :web :confirm t)                           ; make it permanent

;; Capability + version negotiation at connect (LSP-like; open Q7)
(nc-hello :web)
;; => (:base "1.1" :capabilities (:candidate :confirmed-commit :validate)
;;     :sub-vocabularies ((:http-server "1.2")))

;; Lexter parallel: stage an orbit edit, validate, commit atomically with rollback
(nc-edit-config :term-host :candidate
  '((:windows (:window (:@operation :create) (:id 8) (:font "Iosevka")))))
(nc-commit :term-host :confirmed t :timeout 15)
```

### Ergonomics

- **G1 Structured: strong.** Fully structured payloads (XML natively, S-exprs
  here) and structured `rpc-error`s carrying type, severity, and a path to the
  offending node -- a richer error envelope than even SNMP's index (open Q2).
- **G2 Data-not-code: strong.** Edit payloads are data trees the server
  dispatches, bounded by the YANG schema.
- **G3 CQS: strong, with a second read axis.** get/get-config (read) vs
  edit-config/commit (write) is the basic split; but the **config-vs-state**
  distinction is a refinement none of the others had -- "configuration I set"
  vs "operational state I observe" -- which maps directly onto Origin's state
  taxonomy (configuration vs application/session) and onto `status` (observed)
  vs a future `get-config` (declared).
- **G4 Two-tier: yes.** Base operations are universal; YANG models are the
  per-target sub-vocabulary, and `<hello>` advertises which models a target
  speaks.
- **G5 Self-describing: strong, and uniquely version-aware.** `<hello>`
  capability exchange at connect is the model for the DevPlan's open Q7
  (versioning / negotiation) and its LSP comparison; YANG modules are the
  retrievable schema. Where JMX/GraphQL describe *shape*, NETCONF also
  negotiates *version*.
- **G6 Declarative/Δ: the model, and the best of the entire survey.** The
  candidate datastore *is* "stage the desired state, validate it, commit it
  atomically or discard it" -- the DevPlan's declarative `apply` and the
  restart-with-staged-state milestone in one mechanism. Confirmed-commit adds an
  auto-rollback safety net. And the per-node operation attribute unifies
  declarative (`replace`/`merge`) and delta (`create`/`delete`/`remove`) in a
  *single* edit, rather than as two separate verbs -- a cleaner answer to
  goal 6 than treating `apply` and `delta` as wholly distinct.
- **Q5 Addressing: subtree/xpath filters + per-node targeting.** Filters select
  what to read; the per-node operation attribute targets edits within a tree.

**Steal:** candidate/running datastores -> declarative `apply` *and* the
restart-with-staged-state milestone (stage -> validate -> commit/discard);
confirmed-commit auto-rollback -> the safety net for a `configure`/`apply` that
could cut the core's own control link (a genuine meta-OS hazard); per-node
operation attributes -> declarative and delta unified in one edit;
config-vs-state distinction -> refines `status` and maps to the state taxonomy;
`<hello>` capability/version negotiation -> open Q7. **Reject:** XML and the
heavyweight tooling; full YANG modeling-language ceremony (Origin derives its
data model from CLOS and the reader); mandatory datastore separation for trivial
in-image `:thread` orbitals where it would be overkill.


---

## Comparison -- Installment II

| Axis | HTTP safe methods | GraphQL | NETCONF/YANG |
|------|-------------------|---------|--------------|
| **G1 Structured** | Taxonomy yes, wire textual; 206/304 envelope | Strong both ways; response mirrors request | Strong; rpc-error with type/path |
| **G2 Data-not-code** | Strong (methods over paths) | Strong; bound query depth | Strong (edit trees over schema) |
| **G3 CQS** | Two axes: safe x idempotent | query / mutation / subscription | read/write + config-vs-state |
| **G4 Two-tier** | Methods + per-resource representation | Operation kinds + schema fields | Base ops + YANG models |
| **G5 Self-describing** | Weak-moderate (OPTIONS/Allow) | Strongest -- introspection in the query language | Strong + version negotiation (`<hello>`) |
| **G6 Declarative/Δ** | PUT (idempotent) vs POST (delta) -- native | Partial -- declarative *shape*, imperative writes | The model -- candidate/commit + per-node ops |
| **Q5 Addressing** | Path + ETag/If-Match (versioned) | Field arguments: filter / top-N / paginate | Subtree/xpath filter + per-node target |
| **One-line** | The verb classification (safe x idempotent) and conditional concurrency | The selection-set query and introspection-as-query | The declarative datastore + commit + capability negotiation |


## Synthesis for Origin -- Installment II

Where Installment I's trio was uniformly imperative, this trio supplies the
declarative tier and the negotiation tier -- and each does so on a different
front:

1. **HTTP gives Origin its verb classification (G3, G6).** Tag every universal
   verb on *two* axes -- safe? and idempotent? -- not one. Safe-vs-mutating
   gives the read-only connection guarantee (Q1, held "by contract" exactly as
   HTTP holds it); idempotent-vs-not gives the principled line between a
   declarative `apply`/`configure` (idempotent, PUT-like) and an imperative
   `delta` (non-idempotent, POST-like). Add ETag/If-Match conditional requests
   for optimistic-concurrency `configure` and as a concrete versioning seed, and
   206/status classes for the partial-result envelope.

2. **GraphQL gives Origin its query and discovery surface (G1, G5, Q5).** The
   selection set realizes the DevPlan's `:query` selectors literally -- the
   client names the fields, the response mirrors them -- and field arguments
   bring filtering, top-N, and pagination, which the high-cardinality web
   orbital needs and Lexter never demanded. Introspection through the same query
   language is the cleanest `describe` of any reference: discovery is just
   another query.

3. **NETCONF gives Origin the declarative lifecycle the first trio lacked (G6,
   and the state-handoff milestone).** Candidate -> validate -> commit/discard is
   `apply` and restart-with-staged-state in one mechanism; confirmed-commit is
   the auto-rollback safety net for self-modifying control changes; per-node
   operations unify declarative and delta in a single edit; the config-vs-state
   split refines reads and maps onto Origin's state taxonomy; and `<hello>`
   answers the versioning question (Q7).

4. **The contrast pass earned its place.** The `:web` orbital surfaced four
   things Lexter structurally could not: *aggregate/rate queries* (GET on
   `:metrics`; GraphQL `:top n :by`), *configuration-tree declarative state*
   (NETCONF candidate/commit over ports + routes + pool), *readiness != liveness*
   (HTTP HEAD/503, archetype R), and *config collections that are not orbitals*
   (routes edited as data, never confused with managed orbitals) -- which
   sharpens the sub-orbital-vs-domain-object hazard flagged in
   "Representativeness": NETCONF edits routes as configuration, with no
   temptation to treat them as supervised children.

5. **Across both installments, Origin's shape is now legible.** A plausible
   synthesis: JMX/GraphQL-style `describe` (introspection as a query);
   verbs classified on HTTP's two axes and carried in MODIFY's universal
   envelope; SNMP-typed, JMX/GraphQL-selected queries with GraphQL field
   arguments for fan-out; NETCONF datastores for declarative `apply` and state
   handoff; SNMP/GraphQL/NETCONF structured partial-error envelopes; and
   OPTIONS/`<hello>`/`Accept` for capability and version negotiation. The one
   piece still outstanding is *continuous* reconciliation -- NETCONF's commit is
   transactional but one-shot, not a control loop that keeps re-converging. That
   remaining declarative idea belongs to **Kubernetes** (desired-state
   controllers, liveness vs readiness probes), the natural subject of a third
   installment.


---

## Appendix II.A -- Workload Management and the Control Vocabulary

Workload management (WLM) is one of Origin's marquee roadmap features and the
most ambitious claim in the founding vision: a supervisor that reads each
orbital's *declared* semantic intent (workload class, priority, preemptability,
resource hints -- the `(declare (workload ...))` annotations and the existing
`:workload-class` / `:priority` orbital slots) and continuously retunes real OS
resources (cgroups v2 CPU / memory / IO shares) to meet goals, benchmarked
explicitly against z/OS WLM. Structurally, WLM is a **MAPE-K loop** (Monitor,
Analyze, Plan, Execute over a Knowledge model) -- and it is a *consumer* of the
control vocabulary this document evaluates: it reads workload state and writes
allocations through the same verbs. Several elements of the survey therefore bear
directly on it, and the NETCONF auto-rollback model bears on it most of all.


### Confirmed-commit as the safe Execute step of an autonomic loop

The Execute step of a MAPE-K loop is the dangerous one: actually changing
resource allocations. A bad retuning can starve a latency-sensitive orbital, and
in the worst case it can starve *the supervisor or core itself* -- the
generalization of the "a reconfigure can sever the core's own control link"
hazard flagged in Rendition 6. Here the "control link" is CPU time: a supervisor
that de-prioritizes itself into unresponsiveness cannot issue the corrective
re-tuning, and the system is wedged.

NETCONF's **confirmed-commit** is precisely the dead-man's switch for this. A
retuning is applied but auto-reverts after a timeout unless the supervisor
*reconfirms* -- and the reconfirmation predicate is itself a WLM goal evaluation:
reconfirm only if observed goal attainment held or improved. If the change is so
bad that it hobbles the very supervisor that must reconfirm, the timer fires and
the allocation rolls back automatically. The loop is self-correcting even
against its own mistakes.

```lisp
;; WLM retuning expressed through the NETCONF-derived mechanism: stage, validate,
;; apply-with-dead-man's-switch. This is the MAPE-K Execute step made safe.

;; Monitor -- one coherent snapshot: declared intent (config) AND observed
;; consumption (state), heaviest consumers first (GraphQL-shaped selection).
(nc-get :orbit
        :filter '(:workload (:orbitals (:top 5 :by :cpu)
                             :class :priority              ; declared  (get-config view)
                             :cpu% :rss-mb :goal-index)))   ; observed  (get / state view)

;; Plan -- stage a whole new allocation atomically in a candidate datastore,
;; so the orbit never transits a bad intermediate (knob-by-knob) state.
(nc-edit-config :orbit :candidate
  '((:workload
     (:orbital (:@operation :merge) (:name :etl-worker)
               (:priority :background) (:cpu-weight 100))
     (:orbital (:@operation :merge) (:name :term-host)
               (:priority :foreground) (:cpu-weight 800)))))

;; Validate -- the plan must preserve invariants: the core's CPU reserve, each
;; orbital's floor, and share feasibility. Rejects a plan that would starve the
;; supervisor before it is ever applied.
(nc-validate :orbit :candidate)

;; Execute with a dead-man's switch -- apply now, auto-revert in 20 s unless the
;; supervisor reconfirms, and it reconfirms ONLY if goals did not regress.
(nc-commit :orbit :confirmed t :timeout 20)
;; ... supervisor observes the effect over the confirmation window ...
(when (wlm-goal-index-not-worse-p) (nc-commit :orbit :confirm t))   ; make it stick
```

The candidate datastore maps cleanly onto z/OS WLM's notion of activating a whole
**service policy** atomically rather than poking individual goals; `validate`
encodes the feasibility and reserve invariants z/OS achieves through its own
conservatism; and confirmed-commit supplies an explicit safety rail that z/OS
WLM largely substitutes caution for. This is the autonomic-computing "safe
self-tuning" pattern, and it sits squarely under Origin's *Reflective* /
organic-computing framing.


### Declared intent versus observed consumption (config-vs-state)

The DevPlan describes the workload sub-vocabulary as "`status :workload` --
declared intent versus observed consumption." That phrase *is* NETCONF's
config-vs-state distinction, exactly: `get-config` returns the declared targets
(class, priority, resource hints), `get` returns observed reality (CPU%, RSS,
queue depth, goal attainment). The gap between the two strata is the control
signal -- a *performance index* in z/OS WLM terms (observed relative to goal) --
and it is what Analyze consumes to decide whether to Plan a change at all. So
`status :workload` should return both strata side by side, and the vocabulary
should keep "what I asked for" and "what is happening" as distinct, separately
queryable views rather than a single merged report.


### Other intersections across the survey

Beyond NETCONF, several survey elements have a sharper WLM bearing than their
original context suggested, ranked by how load-bearing they are:

1. **HTTP's idempotency axis -> convergence and arbitration.** A *continuous*
   reconciliation loop must Execute with **idempotent** (declarative, PUT-like)
   verbs, or it drifts instead of converging -- re-applying the desired
   allocation must be a no-op when already satisfied. Non-idempotent `delta`
   would be wrong for the loop. Separately, **conditional requests**
   (ETag/If-Match) arbitrate the human-versus-autonomic conflict: the WLM loop
   should set priority only `:if-match` the version it last observed, so it never
   silently clobbers a manual operator override made in the interim.

2. **GraphQL selection + arguments -> the Monitor step.** WLM monitoring wants a
   *coherent single-snapshot* of the whole orbit (many separate polls skew
   against each other), and it wants ranking -- "the top N consumers by CPU."
   GraphQL's nested selection in one round trip and its field arguments
   (`:top 5 :by :cpu`) are exactly that query shape; the Lexter window model
   never demanded it, but the WLM monitor does.

3. **SNMP's Counter32 vs Gauge32 -> metric typology.** WLM's observed metrics are
   of two kinds: monotonic **counters** (CPU-seconds consumed, requests served --
   diffed over time to yield rates) and **gauges** (current RSS, current queue
   depth -- read directly). Typing each `status :workload` leaf as counter or
   gauge tells the core which to rate-difference and which to read as a level --
   a small, concrete borrowing that prevents a whole class of metric errors.

4. **watch / subscribe -> push-driven Monitor.** Polling is not the only path
   into Analyze. SNMP traps and GraphQL subscriptions model a push channel for
   threshold-crossing events (`goal-missed`, `queue-saturated`), letting WLM
   react promptly to a breach between polls rather than waiting for the next
   sweep.

5. **JMX `describe` -> workload schema as live Knowledge.** A *generic* WLM loop
   must operate over heterogeneous orbitals without hardcoding their knobs.
   `describe` reporting each orbital's workload schema -- is it preemptable? is it
   checkpoint-safe? what is its resource-hint shape? -- is how the founding
   vision's per-function `(declare (workload ...))` annotations become the live
   *Knowledge* (the K in MAPE-K) the loop reasons over, rather than static
   configuration the operator must maintain.

Taken together, WLM is the application that exercises nearly every borrowing in
this document at once -- and it is also why Installment III matters: NETCONF's
commit is transactional but one-shot, whereas WLM is a loop that must keep
re-converging. The **continuous** reconciliation Origin needs for autonomic
retuning is the Kubernetes controller pattern, and the confirmed-commit safety
rail described here is what makes such a loop safe to let run unattended.


---

# Installment III -- Erlang/OTP, LSP, Plan 9 / 9P

The first two installments were about the *vocabulary*: verbs, selectors,
schema, the declarative tier. This installment is mostly about the *envelope and
the session* -- how a message is delivered (synchronously or not), how a
connection is opened and its capabilities agreed, how an orbital is introspected
for free, how state crosses a restart, and -- in Plan 9's case -- whether the
envelope should be an RPC datum at all or a synthetic filesystem. These three
references bear on roadmap milestone 1 (envelope and transport) and open
questions Q2 (response envelope), Q3 (streaming), Q4 (state handoff), and Q7
(versioning) more than on the verb set.

One caveat up front: Origin's supervisor *already* descends from OTP -- restart
strategies, restart intensity, child specs, supervised respawn are existing
heritage (see the README). So the fresh lessons from Erlang here are not
supervision but the **control channel**: `call`/`cast`, the `sys` debug
interface, and `code_change`. The shared Lexter scenario and the `:web` contrast
orbital carry over unchanged; the archetypes these three stress hardest are the
*long/cancellable operation* (an expensive `:window :all` or a connection drain)
and *restart with state handoff* (milestone 7).


## Rendition 7 -- Erlang/OTP (`gen_server` `call`/`cast` + `sys` + `code_change`)

A `gen_server` is a process with a behaviour: clients send it messages two ways.
**`call`** is synchronous -- it blocks for a reply, with a timeout.
**`cast`** is asynchronous -- fire-and-forget, no reply. The server's
`handle_call/3` returns a tagged tuple (`{reply, R, S}` / `{noreply, S}` /
`{stop, Reason, R, S}`) that doubles as a response-and-lifecycle envelope.
Orthogonally, the **`sys`** module gives *every* gen_server a free, uniform
introspection channel -- `sys:get_state`, `sys:get_status` -- with no
server-specific code, and **`code_change/3`** transforms live state across a code
version, the OTP hot-upgrade hook.

```lisp
;; call -- synchronous, awaits a reply. This is a DELIVERY axis (sync vs async),
;; NOT a read/write axis: a call may read or mutate.
(orbital-call :term-host '(:status :window 2 :query (:total-lines :pwd)) :timeout 5)
;; => (:reply (:total-lines 1843 :pwd "/home/user/src"))
(orbital-call :web '(:status :metrics :query (:request-rate :p99-latency)))

;; cast -- asynchronous, no reply (the `signal` shape)
(orbital-cast :web '(:drain :grace 30))            ; returns immediately
(orbital-cast :term-host '(:signal :redraw))

;; A control handler returns a structured tuple -- response + lifecycle in one:
;;   (:reply VALUE STATE) | (:noreply STATE) | (:stop REASON [REPLY] STATE)
(defun handle-control (msg state)
  (case (car msg)
    (:status (values :reply (query-window state (getf (cdr msg) :window)) state))
    (:drain  (values :noreply (begin-drain state)))
    (:quit   (values :stop :normal state))))

;; sys -- a UNIVERSAL read-only channel every orbital answers for FREE, no handler
(orbital-get-state  :web)       ; internal state, like sys:get_state
(orbital-get-status :web)       ; state + metadata, like sys:get_status

;; code_change -- live state handoff keyed by version (the restart-with-state model)
(defun code-change (old-vsn state extra)
  (declare (ignore extra))
  (migrate-state old-vsn state))  ; transform application state across a code upgrade
```

### Ergonomics

- **G1 Structured: strong.** Messages are tagged terms; replies are tagged
  tuples pattern-matched at the receiver. Erlang terms are essentially
  S-expressions, so the fit with Origin is native.
- **G2 Data-not-code: strong, with the familiar caveat.** `handle_call`
  dispatches on the message term by pattern; the surface is closed to the
  clauses it matches. (Erlang *can* ship an `{M,F,A}` and `apply` it -- the
  same code-like temptation as JMX `invoke`; idiomatic gen_servers don't, and
  Origin shouldn't.)
- **G3 CQS: present, but on a different axis -- the key insight.** `call`/`cast`
  is **synchronous vs asynchronous**, which is *orthogonal* to safe vs mutating:
  a `call` can mutate, a `cast` can mutate. CQS proper lives elsewhere -- in the
  read-only `sys` channel versus the do-anything `handle_call`. Origin must
  carry *two* axes and not conflate them: safe/mutating (CQS) and sync/async
  (delivery).
- **G4 Two-tier: moderate.** The universal layer is the behaviour itself
  (`call`/`cast`/`info` + `sys` + supervision); the per-server sub-vocabulary is
  the set of message tags each `handle_call` matches.
- **G5 Self-describing: weak for the vocabulary, but `sys` is the gem.** A
  gen_server cannot enumerate which messages it accepts (they are just pattern
  clauses, not introspectable) -- OTP has no `describe`. But `sys:get_state` /
  `get_status` mean state observability costs the server *nothing*. That free
  introspection is the lesson, not schema discovery.
- **G6 Declarative/Δ: weak, except `code_change`, which is outstanding.**
  Messages are imperative. But `code_change` is the deepest *state-handoff*
  model in the survey: version-keyed, in-place transformation of live state
  across a code change -- a different and complementary mechanism to NETCONF's
  staged-config commit.
- **Q5 Addressing: coarse.** The target is a pid or registered name; there is no
  sub-selector grammar -- any sub-addressing rides inside the message term.

**Steal:** the `call`/`cast` **sync/async delivery axis** as a second
classification alongside CQS (status/describe are safe+sync; signal is
mutating+async); `sys:get_state`/`get_status` as the model for *free* universal
introspection -- Origin's default universal-verb handlers derived from
`managed-process` *are* the "`sys` for free" pattern, the concrete realization of
goal 7; `code_change` as the version-keyed state-handoff model for milestone 7;
the `{reply|noreply|stop}` tuple as a unified response/lifecycle envelope (Q2).
**Reject:** conflating sync/async with safe/mutating; a message vocabulary that
is pattern clauses rather than an enumerable, describable schema (Origin needs
`describe`, which OTP lacks); `{M,F,A}`-style apply as a control message.


## Rendition 8 -- LSP (capability negotiation + request/notification + cancel/progress)

LSP is JSON-RPC with three message kinds: **requests** (carry an id, expect a
response), **notifications** (no id, no response), and responses. Its defining
moves are a **capability negotiation** at connect (the `initialize` request
exchanges client and server capabilities, after which features are *gated* on
what was agreed -- "if the client didn't announce it, the server can't rely on
sending it"), **dynamic (un)registration** of capabilities after connect
(`client/registerCapability`, "without a restart"), and first-class
**long-operation lifecycle**: `$/cancelRequest` cancels an in-flight request
(which must still return a response, possibly partial), and `$/progress` streams
progress against a token.

```lisp
;; initialize -- capability + version negotiation at connect; features gated on it
(lsp-initialize :web
  :client-capabilities '(:control-version "1.1"
                         :sub-vocabularies (:http-server)
                         :supports (:progress :cancel :watch)))
;; => (:server-capabilities
;;     (:control-version "1.1"
;;      :sub-vocabularies ((:http-server "1.2") (:metrics "1.0"))
;;      :supports (:progress :cancel)))            ; no :watch -> client must not rely on it

;; request -- has an id, expects a response (sync; correlated by id)
(lsp-request 42 :web '(:metrics/status :query (:request-rate :p99-latency)))
;; notification -- no id, no response (async; the watch/signal direction)
(lsp-notify :web '(:lifecycle/drain :grace 30))

;; long operations: cancel an in-flight request; stream progress against its token
(lsp-request 43 :web '(:status/all-routes))        ; expensive fan-out
(lsp-cancel 43)                                     ; $/cancelRequest -- still gets a (partial) reply
;; server -> client progress, keyed to the request:  (:progress 43 (:done 120 :total 4000))

;; dynamic capability (re)registration after connect, no reconnect
(lsp-register :web '(:capability :metrics/histogram :version "1.0"))

;; namespaced methods: category/action == sub-vocabulary/verb (two-tier shape)
;;   :term-host/window-status   :http-server/route-add   :workspace/describe
```

### Ergonomics

- **G1 Structured: strong.** Structured request/response/notification with
  structured error objects (code + message + data).
- **G2 Data-not-code: strong.** Named methods plus structured params, dispatched
  against a closed, negotiated set.
- **G3 CQS: weak -- the same orthogonality as Erlang.** request vs notification
  is sync/async, not safe/mutating. LSP has no formal safe-method concept
  (unlike HTTP); reads vs writes are by convention. So LSP reinforces the
  delivery axis but contributes nothing to CQS -- a gap Origin must fill from
  HTTP/JMX.
- **G4 Two-tier: strong.** Namespaced methods (`category/action`) are exactly the
  universal-verb-plus-sub-vocabulary shape, cut by feature area.
- **G5 Self-describing: strong, and differently from JMX/GraphQL.** Capability
  negotiation at `initialize` plus dynamic registration is a *connect-time and
  runtime capability set* rather than a queryable parameter schema. It is the
  canonical model for open Q7 (versioning/negotiation) and adds **feature-gating**
  ("only send X if it was negotiated") that a pure `describe` lacks. Origin wants
  both: a handshake for gross capabilities/versions and a queryable `describe`
  for fine schema.
- **G6 Declarative/Δ: weak.** Imperative requests/notifications; no desired-state.
- **Q5 Addressing: namespaced verb + payload selectors.** The method namespaces
  the sub-vocabulary; the params carry the fine selector (a URI + position in
  LSP; an orbital selector in Origin).
- **Long-operation lifecycle: the standout.** `$/cancelRequest` and `$/progress`
  give cancellation and per-operation progress that none of the prior six had
  cleanly -- distinct from event subscription, and exactly what an expensive
  fan-out or a slow drain needs.

**Steal:** capability + version negotiation at connect (`initialize`) with
feature-gating, plus dynamic re-registration without reconnect -> open Q7, and a
connect-time complement to `describe`; request/notification reinforcing the
sync/async axis with id-correlation (Q2); `$/cancelRequest` as cancellable long
operations (with a still-mandatory, possibly-partial reply); `$/progress` as
*operation-scoped* progress streaming, to be distinguished from
*subscription-scoped* event streams (open Q3); namespaced methods for the
two-tier cut. **Reject:** JSON-RPC wire; the single-long-lived-client assumption
(the core multiplexes many orbitals); LSP's ad hoc CQS -- Origin should add the
safe/mutating tag LSP never formalized.


## Rendition 9 -- Plan 9 / 9P (`ctl` and status files; read = query, write = command)

Plan 9 represents every resource as a synthetic filesystem and controls it with
ordinary file operations -- "no use for peculiar `ioctl`." A TCP connection is a
directory `/net/tcp/N/` holding `ctl` (write text commands like `connect
1.2.3.4!80`), `status`/`local`/`remote` (read state), and `data` (the stream).
Killing a process is `echo kill > /proc/PID/ctl`. The 9P protocol underneath is
~17 file operations (`Tversion`, `Twalk`, `Topen`, `Tread`, `Twrite`, `Tcreate`,
`Tremove`, `Tstat`, ...), with `Tversion` first to negotiate version and message
size. The radical idea: **CQS is enforced by the medium** -- reading a file is
inherently the safe query, writing the `ctl` file is the mutation -- and the
**path separates target from aspect**.

```lisp
;; The orbit is a synthetic filesystem. The PATH names target + aspect; READING
;; a file is the safe query, WRITING the ctl file is the mutating command.

;; Q -- read a status file (safe by the nature of the operation)
(9p-read '(:orbit :term-host :window 2 :status))  ; => "lines 1843\npwd /home/user/src\n"
(9p-read '(:orbit :web :metrics))                 ; => "rate 920\np99 14ms\nconns 311\n"

;; C-set / C-delta -- write the ctl file (mutating by the nature of the operation)
(9p-write '(:orbit :term-host :window 2 :ctl) "set poll 250")
(9p-write '(:orbit :term-host :ctl) "open 2")     ; open two windows

;; routes as a DIRECTORY: create = add, remove = delete (delta as filesystem ops;
;; directories aren't written, their entries are created/removed)
(9p-create '(:orbit :web :routes "v2-orders") "path /v2/orders handler orders-v2")
(9p-remove '(:orbit :web :routes "v1-orders"))

;; D -- a directory listing discovers which aspects/controls exist (structural describe)
(9p-walk '(:orbit :web))          ; => (ctl status metrics routes/ conn/ health)
(9p-stat '(:orbit :web :ctl))     ; mode bits reveal writable (mutating) vs read-only

;; Tversion -- negotiate version + msize at attach (the third independent instance)
(9p-version :web :msize 8192 :version "9P-origin.1")
```

### Ergonomics

- **G1 Structured: split, the inverse of GraphQL.** The *envelope* (path +
  read/write) is maximally uniform, but `ctl` and `status` file *contents* are
  typically unstructured text to be parsed -- the MODIFY problem again. Structure
  lives in the namespace, not the payload.
- **G2 Data-not-code: strongest in the survey.** There is no eval surface at all:
  writing bytes to a file is never code, reading is just reading. The control
  plane is viscerally data-only.
- **G3 CQS: the cleanest of all nine, because the medium enforces it.** read =
  safe, write = mutating -- not a tag (SNMP), not a contract (HTTP), but the
  nature of the operation. Per-aspect files (`ctl` writable, `status` read-only)
  put the safe/mutating split into the structure itself.
- **G4 Two-tier: strong, differently cut.** Universal verbs are the file ops
  (`read`/`write`/`walk`/`create`/`remove`); the per-orbital sub-vocabulary is the
  *shape of the synthetic filesystem* each orbital exposes plus its `ctl` command
  grammar.
- **G5 Self-describing: moderate, structural.** A directory listing
  (`walk`/`stat`) discovers which controls and status aspects exist, and mode
  bits reveal read vs write -- a filesystem-shaped `describe`. But the `ctl`
  command grammar inside a file is not self-describing (prose docs, like MODIFY):
  describe-of-structure yes, describe-of-parameters no.
- **G6 Declarative/Δ: moderate, afforded by the shape.** `ctl` writes are
  imperative, but the filesystem affords idioms: read/write a whole config file
  (PUT-like, declarative), and `create`/`remove` directory entries (delta) -- the
  routes-as-directory case shows delta falling out naturally.
- **Q5 Addressing: the best structural separation.** The path cleanly separates
  *target* (the directory: `/orbit/web`, `/orbit/web/routes/v2-orders`) from
  *aspect* (the file: `ctl` vs `status` vs `data` vs `health`). Fan-out is a
  directory listing. The decomposition into per-aspect files is a distinctive
  alternative to one overloaded verb carrying many selectors.

**Steal:** read-is-query / write-is-command as CQS *enforced by the medium* (the
strongest structural CQS, worth emulating even in an RPC envelope by making safe
verbs dispatch only to a read protocol -- open Q1); the path as a
**target + aspect** addressing grammar, and the **per-aspect decomposition**
(separate `ctl`/`status`/`data`/`health` surfaces rather than one verb overloaded
with selectors); directory-listing-as-`describe`; `create`/`remove` as delta;
`Tversion` as a third confirmation of connect-time negotiation. **Reject:**
unstructured text in `ctl`/`status` contents (keep payloads S-expression data);
the full mount/namespace machinery as mandatory (it is an envelope *alternative*,
intriguing but heavy); representing high-cardinality ephemeral populations (every
connection a directory) -- enumerating thousands of `conn/N/` entries is where
the metaphor strains, the same high-cardinality lesson seen from the envelope
side.


---

## Comparison -- Installment III

| Axis | Erlang/OTP | LSP | Plan 9 / 9P |
|------|------------|-----|-------------|
| **G1 Structured** | Strong (tagged terms/tuples) | Strong (JSON-RPC + error objects) | Split -- uniform envelope, textual file contents |
| **G2 Data-not-code** | Strong (`{M,F,A}` caveat) | Strong (negotiated method set) | Strongest -- no eval surface at all |
| **G3 CQS** | Orthogonal -- sync/async, not read/write | Weak -- by convention only | Cleanest -- enforced by the medium |
| **G4 Two-tier** | Behaviour + message tags | Namespaced methods (`category/action`) | File ops + per-orbital filesystem |
| **G5 Self-describing** | Weak vocab; `sys` state for free | Strong -- connect-time capability negotiation + dynamic registration | Moderate -- directory listing as describe |
| **G6 Declarative/Δ** | Weak; `code_change` for state handoff | Weak | Moderate -- whole-file PUT; create/remove delta |
| **Q5 Addressing** | Coarse -- pid/name; rest in payload | Namespaced verb + payload selector | Best -- path = target + aspect; listing = fan-out |
| **One-line** | The sync/async axis, free `sys` introspection, and `code_change` handoff | Connect-time capability negotiation + cancel/progress | Medium-enforced CQS and the filesystem envelope alternative |


## Synthesis for Origin -- Installment III

Where the first two installments fixed the vocabulary, this trio fixes the
envelope and the session -- and several findings converge so strongly across
independent systems that they should be treated as settled:

1. **A second delivery axis: sync vs async.** Erlang (`call`/`cast`) and LSP
   (request/notification) independently invent the same distinction, and it is
   *orthogonal* to CQS. Origin's envelope needs both axes at once: every verb is
   classified safe-vs-mutating (from HTTP/JMX) *and* sync-vs-async (from
   Erlang/LSP). `status`/`describe` are safe + sync (await a reply); `signal` is
   mutating + async (fire-and-forget); `watch` is safe + async-stream. Conflating
   the two axes -- the easy mistake -- must be avoided.

2. **Connect-time capability/version negotiation is settled (Q7).** Three more
   independent inventions -- NETCONF `<hello>`, LSP `initialize`, 9P `Tversion`
   -- agree that a session opens with a version-and-capability handshake. Origin
   should negotiate at connect, with LSP's refinements: feature-gating ("don't
   rely on what wasn't announced") and dynamic re-registration without a
   reconnect. This *complements* the queryable `describe` (JMX/GraphQL): the
   handshake settles gross capabilities and versions; `describe` answers fine
   schema on demand.

3. **Free compliance is a real mechanism, not an aspiration (goal 7).** Erlang's
   `sys` gives every gen_server `get_state`/`get_status` with zero
   server-specific code. This is precisely Origin's plan to derive default
   universal-verb handlers from `managed-process`: the bare orbital is compliant
   because the *core already knows* its lifecycle state. "Free `sys`" is the
   concrete proof the low-compliance-cost goal is achievable.

4. **State handoff now has two complementary models (milestone 7).** Erlang
   `code_change` (version-keyed, in-place transformation of live application
   state) sits alongside NETCONF candidate/commit (staged, validated config
   transactions). They are not competitors: `code_change` is the model for
   migrating *application/session* strata across a code version; candidate/commit
   is the model for staging *configuration*. The deepest milestone should draw on
   both.

5. **Operation lifecycle is distinct from subscription (Q3).** LSP separates
   *operation-scoped* `$/progress` and `$/cancelRequest` (one expensive request,
   streamed and cancellable, still owing a reply) from the *subscription-scoped*
   event stream that `watch` provides. Origin needs both and should not collapse
   them: a slow `:window :all` fan-out wants progress + cancel; a live log tail
   wants subscription.

6. **The envelope shape itself is a live design fork (9P).** Plan 9 shows the
   whole two-tier CQS structure realized *without* an RPC datum: control by
   writing, status by reading, over a synthetic filesystem, with CQS enforced by
   the medium rather than declared. Even if Origin keeps an S-expression RPC
   envelope, two 9P ideas transfer directly: **per-aspect decomposition**
   (distinct `ctl`/`status`/`health`/`data` surfaces per target instead of one
   verb overloaded with selectors) and **listing-as-describe**. The contrast pass
   sharpens the limit: routes-as-a-directory (`create`/`remove` = delta) is
   elegant, but thousands of ephemeral connections as directory entries is where
   the filesystem metaphor strains -- the high-cardinality lesson again, now from
   the envelope side, and an argument that Origin's RPC envelope (with
   GraphQL-style filtered queries) is the better default with 9P's per-aspect
   structure borrowed on top.

7. **What remains.** Across all three installments, Origin's vocabulary (verbs,
   selectors, schema, declarative tier) and its envelope (two delivery axes,
   connect-time negotiation, free introspection, dual state-handoff models,
   operation-vs-subscription streaming) are now well-sourced. The one piece still
   outstanding is the one the WLM appendix and Installment II both pointed to:
   **continuous reconciliation** -- a control loop that turns NETCONF's one-shot
   commit into perpetual convergence, with liveness distinguished from readiness.
   That is the Kubernetes pattern, and it is the subject of the next installment.


---

# Installment IV -- Kubernetes, D-Bus / systemd

The final pair of references is the most pointed of the survey, because it sets
the aspiration directly against the baseline. **Kubernetes** is the model Origin
most wants to emulate -- the continuous, declarative, self-healing
reconciliation loop that every prior installment pointed toward but none
supplied. **D-Bus / systemd** is, in the DevPlan's own words, "a structured
control plane bolted onto an unstructured substrate -- the baseline Origin
improves upon." Studying them together yields the installment's sharpest finding:
both are "structured control planes," but they differ in their *substrate*, and
that difference is exactly Origin's thesis.

Two technologies rather than three; the shared Lexter scenario and the `:web`
contrast orbital carry over unchanged. The archetypes these two stress hardest
are *declarative apply* (archetype A, which Lexter could not surface in
Installment I) and *readiness versus liveness* (archetype R).


## Rendition 10 -- Kubernetes (declarative reconciliation, probes, selectors)

Every Kubernetes object splits into a `spec` (the desired state, owned by the
user) and a `status` (the observed state, owned by a controller). A controller
runs a **reconciliation loop** forever, reading the latest `spec`, observing
actual state, and issuing whatever create/update/delete operations close the gap.
The defining property is that the loop is **level-triggered, not edge-triggered**:
it acts on the *current state*, not on an event stream, which is why it survives
missed events, partitions, and controller restarts. Every reconcile is
**idempotent**. Health is split three ways (liveness / readiness / startup
probes), and sets of objects are addressed by **labels and label selectors**.

```lisp
;; A desired-orbit manifest: declare the orbit you WANT, not the steps to reach it.
;; spec = desired (you own it); status = observed (the reconciler owns it).
(apply-orbit
 '(:orbit
   (:orbital (:name :term-host :kind :lexter-host)
    :labels (:layer :presentation :workload :interactive)
    :spec   (:windows 3 :font "Iosevka" :restart-policy :always)
    :probes (:liveness  (:every 10 :verb (:status :health))   ; fails -> restart
             :readiness (:verb (:status :ready))))             ; fails -> stop serving, keep running
   (:orbital (:name :web :kind :http-server)
    :labels (:layer :presentation :workload :latency-sensitive)
    :spec   (:replicas 1 :listen (8080 8443) :pool (:size 16))
    :probes (:startup   (:verb (:status :booted))              ; gates the others
             :readiness (:verb (:status :ready :query (:accepting-connections)))))))
;; Idempotent + level-triggered: re-applying the same manifest is a no-op; the
;; reconciler acts only on the GAP between spec and status, and self-heals after
;; a missed event or a supervisor restart by re-reading current state.

;; Desired vs observed are two separate lanes (status is its own subresource):
(orbit-get :term-host :spec)     ; => (:windows 3 :font "Iosevka" ...)        what I want
(orbit-get :term-host :status)   ; => (:windows 3 :ready t :uptime 4210 ...)  what is

;; Set-addressing by label selector across the whole orbit -- not one target:
(orbit-select '(:and (:layer :presentation) (:workload :latency-sensitive)))
;; => (:web)

;; Server-side apply: each writer owns the fields it sets; disjoint writers do
;; not clobber, same-field writers get a surfaced conflict (not last-write-wins).
(apply-orbital :web :field-manager :wlm-loop '(:spec (:pool (:size 24))))
```

### Ergonomics

- **G1 Structured: strong.** `spec` and `status` are typed structured objects;
  conditions are structured records. Status is genuinely *data* -- the deliberate
  opposite of `systemctl status`'s log text.
- **G2 Data-not-code: the strongest declarative form in the survey.** A manifest
  is pure desired-state data the reconciler dispatches on; there is no imperative
  step and no eval. The discipline that `spec` must describe desired state and
  *never* an imperative action ("upgrade now") -- because the loop re-reads it
  forever -- is one Origin should adopt wholesale.
- **G3 CQS: moderate-strong.** Read verbs (`get`/`list`/`watch`) versus write
  verbs (`create`/`update`/`patch`/`delete`), each with its own RBAC; and
  `spec`/`status` are separate write lanes with separate verbs and separate
  optimistic-concurrency lanes. CQS by verb classification plus the
  subresource split.
- **G4 Two-tier: strong.** Universal API machinery (typed verbs +
  `apiVersion`/`kind`) over per-type schemas, with **CRDs** extending the type
  set at runtime -- the direct model for Origin's handler-registration of typed
  sub-vocabularies (goals 4 and 5).
- **G5 Self-describing: strong.** API discovery plus OpenAPI/CRD validation
  schemas make the type set and its fields introspectable.
- **G6 Declarative/Δ: the model, and the missing tier finally found.**
  Declarative desired-state plus continuous, level-triggered, idempotent
  reconciliation gives self-healing and drift correction -- precisely the
  DevPlan's `apply` and "desired-orbit reconciler" (milestone 4). Delta is
  available too, via strategic-merge / JSON patch.
- **Q5 Addressing: the richest in the survey.** Namespaced names *plus* labels
  *plus* set-based label selectors (`in`/`notin`/`exists`) *plus* field
  selectors. This extends Origin's selector grammar from "one orbital + a
  sub-selector" to "any *set* of orbitals matching a predicate" -- fleet
  addressing.
- **Health and resources.** Liveness / readiness / startup probes resolve the
  Health sub-vocabulary directly; QoS classes and resource requests/limits feed
  straight into the WLM appendix's model.

**Steal:** declarative desired-state + continuous **level-triggered idempotent**
reconciliation (completes goal 6, *is* milestone 4's reconciler; level-triggered
= self-healing and robust to missed events -- and Origin's poll-based supervisor
is already proto-this, so the upgrade is evolutionary); **spec/status
separation** (the decisive third independent invention of declared-vs-observed);
**liveness vs readiness vs startup** (resolves `status :health` -- restart vs
stop-serving vs wait); **labels + set-based selectors** as fleet addressing (Q5),
essential for the layered service mesh and for WLM ("all `:latency-sensitive`
orbitals"); CRD-style typed extension as the sub-vocabulary registration model;
server-side **field ownership** as multi-writer arbitration (finer than HTTP's
`If-Match` -- the clean answer to the human-operator-versus-WLM-loop conflict).
**Reject:** YAML, etcd, and the network-distributed/eventual-consistency
assumptions; the operational weight (admission webhooks, full RBAC) as mandatory
for a single-host nexus that mostly reconciles co-located images.


## Rendition 11 -- D-Bus / systemd (typed bus + fixed verbs over an opaque substrate)

D-Bus is a structured, typed, introspectable message bus with **four-level
addressing** -- *bus name* (`org.freedesktop.systemd1`) / *object path*
(`/org/freedesktop/systemd1`) / *interface* (`...systemd1.Manager`) / *member* --
and three kinds of member: **methods** (call/return), **signals** (broadcast
events), and **properties** (`Get`/`Set`/`GetAll`, with a `PropertiesChanged`
signal). systemd is built on top: a small **fixed verb set**
(`Start`/`Stop`/`Restart`/`Reload`/`Kill`/...) over D-Bus, with unit files as
declarative config carrying **dependency ordering** (`Requires`, `Wants`,
`After`, `Before`, `Conflicts`). It is a genuinely structured protocol -- and the
cautionary baseline at the same time.

```lisp
;; Four-level addressing: service / object-path / interface / member.
;; method call (call/return) -- like a JMX operation or a gen_server call
(dbus-call :term-host '(:path (:window 2)) :iface :lexter.window
           :method :clear-scrollback)

;; properties: Get / Set / GetAll, plus a PropertiesChanged signal (watch)
(dbus-get     :term-host '(:path (:window 2)) :iface :lexter.window :prop :total-lines)
(dbus-set     :web '(:path :pool) :iface :http.pool :prop :size 16)
(dbus-get-all :web '(:path :metrics) :iface :http.metrics)

;; signals: broadcast events (the watch direction)
(dbus-subscribe :web :iface :http.routes :signal :route-saturated)
;; <- (:route-saturated :path "/v2/orders" :rate 9000)

;; Introspectable: a real describe -- interfaces, methods (typed args), signals, props
(dbus-introspect :web '(:path :root))
;; => (:interfaces ((:http.metrics (:properties ((:request-rate :type :u)
;;                                                (:p99-latency  :type :u))))
;;                  (:http.pool    (:methods ((:drain (:grace :u)))
;;                                  (:properties ((:size :type :u :writable t)))))))

;; systemd layer: a small FIXED universal verb set + a declarative unit with
;; dependency ordering -- but the service itself is an OPAQUE process.
(systemctl :start  :web)
(systemctl :reload :web)                 ; re-read config without a restart
(systemctl :status :web)
;; => (:active-state :active :sub-state :running :main-pid 4821 :result :success)
;;    ... but the rich, service-specific detail is journal LOG TEXT, not data.
(define-unit :web :requires (:db) :after (:db :network) :wanted-by :presentation.target)
```

### Ergonomics

- **G1 Structured: split.** D-Bus is strongly structured (typed marshalling,
  typed arguments); systemd's properties are structured (`ActiveState`,
  `SubState`), but `systemctl status`'s rich content degrades to journal log text
  -- the structure thins exactly where service-specific state lives.
- **G2 Data-not-code: strong.** Typed messages dispatched against interfaces; no
  eval surface.
- **G3 CQS: moderate.** Property `Get` (read) versus `Set` (write); methods may be
  either, with no inherent safe tag; systemd verbs classified only by convention
  (`status` reads; `start`/`stop` write). JMX-like, but weaker.
- **G4 Two-tier: strong, and notably structured in its addressing.** Universal:
  the D-Bus method/property/signal machinery plus systemd's fixed verbs.
  Per-target: the interfaces each object exposes. The four-level name is the most
  explicitly layered address in the survey.
- **G5 Self-describing: strong protocol, thin ecosystem.** D-Bus `Introspectable`
  returns interfaces, methods (with typed argument directions), signals, and
  properties -- a real `describe`, on par with `MBeanInfo`. But systemd-managed
  *services* usually expose no rich D-Bus interface of their own; introspection
  covers systemd's objects, not the opaque daemons. The describe stops at the
  manager boundary.
- **G6 Declarative/Δ: weak-moderate.** Unit files are declarative static config
  with genuinely useful dependency ordering (`After`/`Requires`/`Conflicts`), but
  this is startup configuration plus event-driven transitions -- *not* a
  continuously reconciled desired-state (closer to NETCONF `<startup>` than to a
  Kubernetes loop). `reload` (re-read config without restart) is, however, a
  clean precedent for Origin's no-restart `configure`.
- **Q5 Addressing: strong four-level, but per-target.** Structured
  service/path/interface/member, with no set-based selector like Kubernetes
  labels.
- **The cautionary core.** D-Bus is a fine protocol, but on Linux every program
  is a byte pipe that *need not* speak it; systemd treats services as opaque
  (start/stop/signal/exit-code/journal), and service-specific state is whatever
  each unit chose to expose. The structure is **opt-in and stops at the process
  boundary**. This is the baseline Origin structurally beats: its orbitals are
  homogeneous CL images already sharing a reader, printer, and condition system,
  so a structured vocabulary is the *default* substrate, not something bolted on.

**Steal:** D-Bus's typed `Introspectable` as another `describe` confirmation; the
**methods / properties / signals** split (= operations / attributes /
notifications -- convergent with JMX, strong evidence for that tripartite
structure); the four-level structured address; `PropertiesChanged` as
change-notification `watch`; systemd's small fixed universal verb set (the direct
cousin of Origin's universal verbs) and its **dependency ordering**
(`After`/`Requires`/`Conflicts`) as the model for the Topology sub-vocabulary and
start-up ordering of the orbit; `reload` as the no-restart `configure` precedent.
**Reject (the cautionary baseline):** structure that is opt-in and stops at the
process boundary (Origin's homogeneity makes it default); status that degrades to
log text -- the scrape-the-log failure G1 exists to reject; unit files as static
startup config rather than a live reconciled desired-state (Kubernetes does this
better); the object/path/interface ceremony, heavier than a CL S-expression
envelope needs.


---

## Comparison -- Installment IV

| Axis | Kubernetes | D-Bus / systemd |
|------|------------|-----------------|
| **G1 Structured** | Strong -- typed spec/status, structured conditions | Split -- typed bus, but `systemctl status` degrades to log text |
| **G2 Data-not-code** | Strongest declarative -- desired-state data, no steps | Strong -- typed messages, no eval |
| **G3 CQS** | Read vs write verbs + spec/status lanes | Property Get/Set; methods either; systemd verbs by convention |
| **G4 Two-tier** | Typed verbs over schemas; CRDs extend | D-Bus machinery + fixed verbs; four-level address |
| **G5 Self-describing** | Strong -- API discovery + OpenAPI/CRD schemas | Strong protocol (`Introspectable`), thin ecosystem |
| **G6 Declarative/Δ** | The model -- continuous level-triggered reconciliation | Static unit config + ordering; no live reconcile |
| **Q5 Addressing** | Richest -- names + labels + set-based selectors | Structured four-level, but per-target only |
| **One-line** | The continuous declarative reconciler -- the missing tier | A good protocol on an opaque substrate -- the baseline to beat |


## Synthesis for Origin -- Installment IV

This pairing closes the survey by setting the destination beside the
starting line:

1. **Kubernetes supplies the missing tier.** Continuous, level-triggered,
   idempotent reconciliation is the `apply` / desired-orbit reconciler
   (milestone 4) that completes goal 6. NETCONF gave a one-shot transactional
   commit; Kubernetes gives the loop that keeps re-converging. **Level-triggered**
   is the property to internalize: reconcile to the *current observed* state, not
   to an event stream, so the system self-heals after missed events or a
   supervisor restart -- and since Origin's supervisor already polls
   `process-alive-p` and acts on current state, it is *already* a proto-reconciler;
   the declarative `apply` is its natural completion.

2. **Declared-versus-observed is now decisively settled.** `spec`/`status` is the
   third independent invention of the same split (after NETCONF config-vs-state
   and the WLM declared-vs-observed). Origin should make it a first-class envelope
   distinction: `status` returns observed reality; a `get-spec` returns declared
   intent; the gap is what the reconciler and the WLM loop both consume.

3. **Health is resolved.** Liveness versus readiness versus startup answers the
   Health/readiness candidate sub-vocabulary precisely: `status :health` must
   distinguish *alive* (else restart), *ready* (else stop routing work to it but
   keep it running), and *started* (gate the other two) -- three states with
   three different consequences, not one boolean.

4. **Addressing reaches fleets.** Kubernetes labels and set-based selectors
   extend the selector grammar (Q5) from "one orbital plus a sub-selector" to "any
   set of orbitals matching a predicate" -- exactly what the founding vision's
   layered service mesh (data / processing / presentation) and the WLM loop
   ("select all `:latency-sensitive` orbitals") require.

5. **The baseline, sharpened -- and the survey's punchline.** D-Bus is a good
   structured protocol worth borrowing from (introspection, the
   methods/properties/signals split, typed addressing, dependency ordering), but
   systemd-over-D-Bus is the cautionary tale the DevPlan names: structure bolted
   onto a heterogeneous, opaque-process substrate, opt-in and boundary-limited,
   with status degrading to log text. The two technologies of this installment
   are both "structured control planes," yet they differ in their *substrate*:
   Kubernetes' is homogeneous and declarative by construction, so structure is the
   default; systemd's is heterogeneous byte-pipe processes, so structure is bolted
   on. **Origin resembles systemd on the surface -- an init/process manager -- but
   resembles Kubernetes underneath**, because its orbitals are homogeneous CL
   images that already share a reader, printer, and condition system. It should be
   engineered as the former pretending to be the latter no longer: a homogeneous
   declarative object model wearing a process-manager's face.

6. **Convergences the full survey confirms.** The methods/properties/signals
   (operations/attributes/notifications) tripartite recurs in JMX and D-Bus;
   `describe` in JMX, GraphQL, D-Bus, and Kubernetes; declared-vs-observed in
   NETCONF, WLM, and Kubernetes; connect-time negotiation in NETCONF, LSP, and
   9P; the universal-verbs-plus-typed-sub-vocabulary two-tier in every single
   reference. Independent invention on this scale is the strongest possible signal
   for what Origin's design should keep.

With this installment the field is surveyed end to end: the universal verbs and
their two-axis classification, the selector grammar from single target to fleet,
`describe` and capability negotiation, the declarative reconciliation tier, the
envelope-and-session layer, and the baseline to surpass. The **final piece** will
draw these eleven renditions together into a single set of conclusions and
concrete recommendations to inform the engineering of Origin's IPC and control
system.

---

# Renditions Reflected Upon

Comparing the aforementioned eleven technologies and building their Lisp-formatted
renditions brings to light a range of considerations for the Origin IPC design.
Let's consider the lessons learned in exploration.

## SNMP Considerations

Its most interesting quality is the MAX-ACCESS property for fine-grained read/
write/create capability specification. The error status/error index structure
are also instructive along with the table-walking `:all` fan-out. MAX-ACCESS
shows that CQS belongs in the schema, not just per-verb. The typed, access-
tagged leaves are a good model for the sub-vocabulary schema. The counter/
gauge metric typology is also important for WLM, as is the trap functionality.

## z/OS MODIFY Considerations

It validates Origin IPC's essential model: a two-tier model of general commands
with service-specific sub-vocabularies. Its start/stop/cancel lifecycle is
instructive as well.

## JMX MBeans Considerations

The MBeanInfo pattern is an excellent model for the `describe.` There are good
lessons to be learned for CQS as well, like the attribute/operation split,
and ObjectName's domain + key/value selector with pattern fan-out. This helps
to inform Origin's selector grammar. Origin's addressing model could hybridize
the JMX and SNMP conventions. Annotations to `describe` data are key for
implementing WLM features.

## HTTP Considerations

HTTP separates verbs on two axes: safe/unsafe and idempotent/or not. This model
should be ported to Origin. The Accept/Vary content negotiation is also useful.
The PUT/POST duality is also an important validation of a planned Origin feature.
ETag + If-Match's addressing system is another worty addition.

## GraphQL Considerations

GraphQL is a declarative query format with strong read/write/stream functional
distinction. The SQS model is strong; it can be seen as an extension of the JMX
model adding streaming. Its introspection system is an excellent model for
`describe`, with capabilities discoverable through the same query language as
the rest of the system. The field arguments for filtering/top-N/pagination
are key ideas to uptake as well, along with partial success responses with
data plus errors. The selection + arguments model is also invaluable for
WLM.

## NETCONF Considerations

The standard for declarative configuration; the candidate datastore is the
best model for the DevPlan's declarative `apply`. The config-vs-state
dichotomy is another key feature to mirror in Origin. The per-node operation
attribute unifies declarative and delta in a single edit. The `<hello>`
capability handshake is instructive. The confirmed commit auto-rollback is
an essential figure for a configuration change that could cut contact
with the target. This is important for the MAPE-K loop implemented by the
planned Origin workload management system.

## Erlang/OTP Considerations

The call/cast distinction is key here. It introduces a new verb axis:
synchronous/asynchronous. The sys:get_state and get_status actions
allow for state observability at no cost. The code_change model is an
excellent reference for state handoff behavior. The `{reply|noreply|stop}`
tuple is a good unified response/lifecycle envelope. An interesting note:
does the call/cast addition mean a mandate for a three-axis verb space?
Safe/unsafe, idempotent/not and sync/async.

## LSP Considerations

The capability and version negotiation at `initialize` is a potent model,
with feature-gating and dynamic re-registration without reconnect. The
request/notification axis reinforces the sync/async axis concept. The
`$/progress` as operation-scoped progress streaming is an excellent
distinction from subscription-scoped event streams. LSP's `$/progress`
and `$/cancelRequest`, the expensive requests, are separate from the
subscription-scoped event stream that `watch` provides.

## Rendition 9 Considerations

The CQS model is the cleanest of the reference technologies; the data-not-
code enforcement is profound as well. The read-is-query, write-is-command
structure will be invaluable for Origin. The addressing model is one of
the best as well, with target + aspect path dichotomy and per-aspect
decomposition. The Tversion confirms again the connect-time negotiation
convention.

## Kubernetes Considerations

Kubernetes fills in the critical missing piece: continuous reconcilation
for self-healing and drift correction based on a target state. Its
duality of state (specified) and status (actual) is a key feature needed
in Origin. Its powerful addressing will be a welcome addition. Its
Health and Resources vocabularies may be ported for Origin's health and
WLM systems. The labels and set-based selectors as fleet addressing is
another important feature, along with server-side field ownership as
multi-write arbitration.

## D-bus Considerations

The Introspectable feature is more validation for the `describe`
structure, and the methods/properties/signals split is convergent
with JMX. The concept of the small universal verb set is something
already targeted for Origin IPC, and the systemd dependency ordering
is a model for Origin's topology logic. The `reload` verb elegantly
expresses the idea of no-restart configuration change.


---

# Summary and Conclusions: Designing Impulse

The control vocabulary has a name: **Impulse** -- *Interactive Manifold
Process-Uniting Lexicon as Symbolic Expressions*. The expansion is itself a
design brief. *Interactive*: it is a live control surface, not a static config
format. *Manifold*: one lexicon spans many orbital kinds -- native Lexter
windows, image orbitals, and foreign adapters. *Process-Uniting*: it is the
common idiom that binds a heterogeneous process network into one administrable
whole. *Lexicon as Symbolic Expressions*: the medium is S-expression data read
and dispatched, never code evaluated.

This section consolidates the eleven renditions and the per-technology
reflections above into design conclusions for Impulse. It does three things:
resolves the verb-classification question raised in the Erlang reflection,
states the cross-survey decisions where independent invention has effectively
settled the design, and -- crucially -- pressure-tests the result against the
foreign-orbital adapter requirements from `DevPlan.ForeignOrbitals.md`, so that
Impulse is shaped by a real non-Lisp target (nginx) and not only by the native
Lexter case.


## The verb space: two dimensions, not three

The Erlang reflection asks the right question: with `call`/`cast` adding a
sync/async distinction on top of HTTP's safe/unsafe and idempotent/not, does
Impulse need a *three-axis* verb space? The answer is **no -- it is two
dimensions**, because two of the three candidate axes are not independent.

The relations are:

- **Safe implies idempotent.** A safe verb observably mutates nothing, so
  applying it once or many times yields the same result. The cell "safe but
  non-idempotent" is therefore *empty*. What looked like two independent boolean
  axes (safe/unsafe x idempotent/not) is really a single **ordered effect
  ladder** with three reachable rungs:

  | Effect class | Meaning | Prior-art anchor | Impulse verbs |
  |--------------|---------|------------------|---------------|
  | **safe** | no observable mutation (hence idempotent) | HTTP GET/HEAD; SNMP read-only; 9P read; JMX attribute-get | `describe`, `status`, the read side of `watch` |
  | **idempotent** | mutating, but repeating reaches the same end state | HTTP PUT/DELETE; K8s `apply`; NETCONF `merge`/`replace` | `configure`, `apply`, `start`, `stop`, `restart` |
  | **effecting** | mutating and *non*-repeatable; each call accumulates | HTTP POST; NETCONF `create`/`delete`; `delta` | `delta`, `signal` |

- **Delivery is the genuinely independent second dimension.** Synchronous
  (await a correlated reply) versus asynchronous (fire-and-forget, or a streamed
  reply) is orthogonal to effect, and it is a property of the *message*, not the
  *verb* -- the same logical request can sometimes be issued either way
  (Erlang `call`/`cast`; LSP request/notification). The two dimensions populate
  a 3 x 2 grid, every cell of which is real:

  | Effect \ Delivery | sync (await reply) | async (fire / stream) |
  |-------------------|--------------------|-----------------------|
  | **safe** | `status`, `describe` | `watch`/`subscribe` (read stream) |
  | **idempotent** | `configure`/`apply` awaiting result+error (e.g. nginx `-t` verdict) | `apply` handed to a reconciler that converges in the background |
  | **effecting** | `delta` awaiting confirmation | `signal` fire-and-forget |

Three operational laws fall out of this structure, and they are the payoff of
resolving the axes cleanly:

1. **Effect maps onto the permission tiers** (open Q6). Safe verbs are allowed
   on read-only connections and need no audit (open Q1, held by construction and
   by contract -- the HTTP-safe and 9P-read lessons); idempotent and effecting
   verbs require a read-write capability and are audited; arbitrary eval remains
   a separate, privileged break-glass tier.
2. **A control loop may auto-issue only safe and idempotent verbs -- never
   effecting ones.** The desired-orbit reconciler, any retry logic, and the WLM
   MAPE-K loop repeat their actions by nature; repeating an *effecting* verb
   (`delta`, `signal`) is a bug. This is why the declarative `apply` (idempotent)
   is the loop's Execute verb and `delta` is reserved for explicit, one-shot
   operator intent -- the HTTP PUT-vs-POST lesson, now an enforced invariant.
3. **Effect is a static verb property (discoverable via `describe`); delivery is
   a per-message property (constrained by what the verb supports).** So
   `describe` reports each verb's effect class and the delivery modes it offers,
   and the envelope carries the chosen delivery mode plus a correlation id for
   sync replies or a token for streamed ones.


## What the survey settled

Some design choices recur across so many independent systems that the
convergence itself is the argument. These should be treated as decided:

1. **Two tiers: universal verbs + a typed sub-vocabulary.** Present in *every*
   reference (the SNMP MIB, the z/OS `MODIFY` sub-language, JMX MBeans, NETCONF
   YANG models, LSP namespaces, the 9P per-orbital filesystem, K8s CRDs, D-Bus
   interfaces). This is Impulse's spine; it was the working hypothesis and the
   survey confirms it without exception.
2. **`describe` is mandatory, free, and queried like everything else.** JMX
   `MBeanInfo`, GraphQL introspection, D-Bus `Introspectable`, K8s API discovery,
   and 9P directory listing all converge on self-description; GraphQL's
   "introspection through the same query language" is the cleanest realization.
   The schema `describe` returns should carry, per leaf, its type (SNMP SMI),
   its effect class, and its read/write access (SNMP MAX-ACCESS in the schema,
   not merely per-verb). And it is free: default universal-verb handlers derived
   from `managed-process` give a bare orbital compliance with no extra code --
   the Erlang `sys:get_state` pattern (goal 7).
3. **A connect-time capability/version handshake** (open Q7). NETCONF `<hello>`,
   LSP `initialize`, and 9P `Tversion` independently invent it. Impulse opens a
   session by negotiating versions and gross capabilities, with LSP's refinements
   (feature-gating, dynamic re-registration without reconnect); `describe`
   answers fine schema on demand. Handshake and `describe` are complementary,
   not redundant.
4. **A hybrid selector grammar, from one target to a fleet** (open Q5). Compose
   SNMP's namespaced path, JMX `ObjectName`'s key/value selector with pattern
   fan-out, GraphQL's field arguments (filter / top-N / pagination for
   high-cardinality populations), and Kubernetes labels with set-based selectors
   for addressing *sets* of orbitals. Keep distinct the two things the Lexter
   case blurred: addressing *through* to a managed sub-orbital versus addressing
   a *domain object or aspect* of one orbital.
5. **Declared versus observed is first-class.** NETCONF config-vs-state, the WLM
   declared-vs-observed, and Kubernetes `spec`/`status` are three inventions of
   one idea. `status` returns observed reality; a `get-spec`/`get-config` returns
   declared intent; the gap drives both reconciliation and WLM.
6. **A declarative `apply` with staged validation, plus an explicit `delta`.**
   Kubernetes supplies continuous, level-triggered, idempotent reconciliation
   (the desired-orbit reconciler, milestone 4); NETCONF supplies
   candidate -> validate -> commit/discard and the confirmed-commit auto-rollback
   that protects a change which might sever the controller's own link; NETCONF's
   per-node operations unify declarative and delta in one edit. This is the
   declarative tier the first installments lacked, now sourced.
7. **A structured response / error / partial envelope** (open Q2). SNMP
   `error-status` + `error-index`, NETCONF `rpc-error` with a path, GraphQL's
   data-plus-errors, and HTTP's status classes + 206 Partial Content all model a
   structured outcome that survives fan-out (some `:window :all` targets succeed,
   some fail).
8. **Two distinct streaming kinds.** Subscription-scoped `watch` (events and
   logs -- SNMP traps, GraphQL subscriptions, D-Bus signals) is *not* the same as
   operation-scoped progress and cancellation (LSP `$/progress` /
   `$/cancelRequest` for a slow fan-out or drain). Impulse needs both and must
   not conflate them (open Q3).
9. **Two complementary state-handoff models** (milestone 7). Erlang
   `code_change` (version-keyed, in-place transformation of application/session
   state) and NETCONF candidate/commit (staged configuration) cover the deepest
   verb from two angles; handoff is per-orbital, keyed by state stratum, and may
   be empty.


## Squaring Impulse with foreign orbitals

The Foreign Orbitals plan is the discipline that keeps Impulse honest beyond the
native case, and it sharpens several conclusions above. Its central constraint
is **adapter-as-respondent**: a foreign program (nginx, Redis, PostgreSQL)
cannot answer Impulse; a CL adapter answers *on its behalf*, translating verbs
into the program's native control surface. This has direct consequences for the
lexicon's design:

- **It is the hardest possible proof of "data, not code" (G2).** A foreign
  process has no catchable conditions, no shared heap, and -- decisively -- *no
  eval*. An Impulse verb must therefore be answerable as pure translation to
  files-and-signals (nginx), a wire protocol (Redis `CONFIG SET`/`INFO`), or SQL
  plus `SIGHUP` (PostgreSQL). Eval-as-control is not merely discouraged for
  foreign orbitals; it is *impossible*. This retroactively validates the closed,
  dispatched-datum design: the lexicon must mean something to a respondent that
  can only translate, never evaluate.

- **The nginx requirements map onto the settled design, confirming it.** Each
  demand the adapter places on Impulse lands on a conclusion already reached:

  | nginx adapter demand | Impulse element it confirms |
  |----------------------|-----------------------------|
  | Validation before apply (`nginx -t` before SIGHUP) | declarative `apply` with candidate -> validate -> commit (NETCONF), abort-and-report on failure |
  | Structured error returns (`nginx -t` file/line/message) | the structured error envelope, not a string (Q2) |
  | Declarative desired-state config | `apply` over `delta` for config-heavy domains; the typed S-expression config *is* the spec |
  | Graceful-vs-fast stop (SIGQUIT vs SIGTERM) | a lifecycle-verb parameter (`stop`/`restart` mode), surfaced via `describe`; first instance is the configurable `:image` stop signal |
  | Read-only status with selectable fields (`stub_status` + log metrics) | `status :query (...)` field selection + the safe effect class |
  | Adapter-as-respondent | every verb implementable by translation, assuming no conditions/heap/eval in the target |

- **Health versus readiness is forced into the lexicon, not optional.** nginx's
  "master alive" (`:image` liveness) differs from "serving on the port"
  (`stub_status` reachable) -- the adapter answers liveness from the process and
  readiness from the foreign surface. This is precisely the Kubernetes
  liveness/readiness/startup split, and the adapter case makes it a requirement
  of `status :health` rather than a nicety.

- **The Redis/PostgreSQL contrast is the ultimate two-tier validation.** The
  same universal verbs (`describe`, `status`, `configure`/`apply`, `restart`)
  resolve to wholly different native surfaces -- files and signals for nginx, a
  RESP wire protocol for Redis, a config file plus `ALTER SYSTEM` over SQL for
  PostgreSQL. The universal tier is genuinely universal only because the typed
  sub-vocabulary's *implementation* is adapter translation, and `describe` must
  report each adapter's declared sub-vocabulary since no two foreign programs
  agree. State handoff likewise varies: nginx is effectively stateless across
  restarts (an empty handoff), while databases and session stores make
  `restart`-with-state-handoff meaningful -- so the handoff verb must be optional
  and adapter-declared.

- **Transport-agnosticism is reinforced (G8).** Because an adapter may run
  in-core or as its own image (the plan's topology (a) versus (b)) as a pure
  deployment choice, the same Impulse envelope must serve an in-image call and an
  inter-process message identically. The lexicon is defined over the datum, not
  the carrier.


## Recommendations for engineering Impulse

Drawing the survey, the verb-space resolution, and the foreign-orbital
constraints together, the concrete shape to build:

1. **Envelope first** (milestone 1). One S-expression request datum -- `:op`
   (verb), `:target` (selector), `:query`/`:args`, `:id` (correlation),
   `:delivery` (sync/async) -- and one uniform response datum with success /
   structured-error / partial variants. Define it over the datum so it rides an
   in-image call and an IPC message unchanged.
2. **Classify every verb on the effect ladder** (safe / idempotent / effecting)
   and declare its supported delivery modes; derive the permission tier from the
   effect class; forbid control loops from auto-issuing effecting verbs.
3. **Make `describe` free and mandatory:** default universal-verb handlers from
   `managed-process` (the `sys` pattern), typed sub-vocabularies via
   handler-registration, schema reporting per-leaf type + effect + access; and
   the same `describe` is what an adapter implements for a foreign orbital.
4. **Open sessions with a capability/version handshake**, feature-gated, with
   dynamic re-registration; complement it with on-demand `describe`.
5. **Build the declarative `apply` as candidate -> validate -> commit/discard
   with confirmed-commit**, level-triggered toward a desired orbit, with an
   explicit one-shot `delta` for additive/subtractive operator intent; `nginx -t`
   is the canonical external validator the shape must accommodate.
6. **Adopt the structured response/error/partial envelope** for fan-out and for
   foreign validators that return file/line/message diagnostics.
7. **Separate `watch` (subscription) from operation progress/cancel**, and make
   the safe-stream and operation-stream distinct envelope behaviors.
8. **Treat state handoff as optional and adapter-declared**, keyed by the state
   taxonomy (configuration / application / session / binary / ephemera), drawing
   on `code_change` and candidate/commit.
9. **Hold the foreign-orbital invariant as an acceptance test for the whole
   lexicon:** every verb must be implementable by an adapter translating to a
   foreign control surface, with no assumption that the respondent can catch a
   condition, share a heap, or evaluate code. If a proposed verb cannot be
   answered by the nginx or Redis adapter, it is mis-designed.

The survey is complete. Across eleven technologies, four installments, and a
workload-management appendix, the field that Impulse must occupy has been mapped
end to end: a two-dimensional verb space over a two-tier, self-describing,
declared-versus-observed, declaratively-reconciled lexicon of S-expression data
-- structured where systemd is textual, homogeneous where Linux is a byte pipe,
and answerable even by a process that speaks no Lisp. What remains is to build
it, in the order the Control Vocabulary roadmap sets out, with the foreign
adapter kept on the bench as the test that the lexicon never quietly assumes its
respondent is a native orbital.