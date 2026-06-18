# Control Vocabulary: Prior-Art Evaluation (I) -- SNMP, z/OS MODIFY, JMX

This document evaluates the control vocabularies of the first three prior-art
technologies named in `DevPlan.ControlVocabulary.md`: **SNMP** (GET/SET over
MIBs), the **z/OS `MODIFY` (`F`)** operator command, and **JMX MBeans**. For
each, it renders a small subset of the technology's grammar as Common Lisp
forms, grounds the rendition in one shared Origin scenario, and scores the
ergonomics against a rubric drawn from the DevPlan's design goals. The aim is
not to specify Origin's vocabulary but to learn from each ancestor what to
borrow and what to avoid when designing the control surface for Origin's
orbitals.

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
;;     (#oid(:lexter :window-table :pwd         2) . "/home/sloane/src"))

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
;;    "TERMHOST: WINDOW 2 LINES=1843 PWD=/home/sloane/src"

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
;; => (:window 2 :lines 1843 :pwd "/home/sloane/src")

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
;; => (:total-lines 1843 :pwd "/home/sloane/src")

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

## Comparison

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


## Synthesis for Origin

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
