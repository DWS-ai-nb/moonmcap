///|
fn journal_test_plan() -> @moonmcap.AttachmentExportPlan raise @moonmcap.McapError {
  batch_test_selection(b"payload").plan_exports(info => info.offset.to_string())
}

///|
test "modifying public receipt and target snapshots cannot change journal state" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  let targets = plan.targets()
  targets.clear()
  assert_eq(plan.info().records, 2)
  assert_eq(journal.info().planned, 2)
  ignore(
    journal.run(
      (_, _) => {
        @moonmcap.attachment_export_destination(
          @moonmcap.new_write_sink(fn(_) { () }),
          fn() { () },
          fn() { () },
        )
      },
      fn(_) { () },
      max_files=1,
    ),
  )
  let snapshot = journal.snapshot()
  let receipts = journal.receipts()
  assert_eq(receipts.length(), 1)
  receipts.clear()
  assert_eq(journal.info().published, 1)
  assert_eq(journal.receipts().length(), 1)
  assert_eq(journal.snapshot(), snapshot)
  assert_false(journal.info().complete)
  let done = journal.run(
    (_, _) => {
      @moonmcap.attachment_export_destination(
        @moonmcap.new_write_sink(fn(_) { () }),
        fn() { () },
        fn() { () },
      )
    },
    fn(_) { () },
  )
  assert_eq(done.published, 2)
  assert_true(done.complete)
}

///|
test "attachment export journal resumes only after checking published outputs" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => {
    "sha256:test-source"
  })
  let stored : Map[String, Bytes] = Map([])
  let mut saved = b""
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    key,
    _,
  ) => {
    if stored.contains(key) {
      raise @moonmcap.io_error("attempted to create an existing output")
    }
    let out = @buffer.Buffer::Buffer()
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(bytes => out.write_bytes(bytes[:])),
      () => stored[key] = out.to_bytes(),
      fn() { () },
    )
  }
  let first = journal.run(create, bytes => saved = bytes, max_files=1)
  assert_eq(first.published, 1)
  assert_false(first.complete)
  let mut verified = 0
  let resumed = @moonmcap.resume_attachment_exports(
    plan,
    _ => "sha256:test-source",
    saved,
    receipt => {
      verified += 1
      stored
      .get(receipt.destination)
      .map(bytes => bytes.length().to_uint64() == receipt.source.data_size)
      .unwrap_or(false)
    },
  )
  assert_eq(verified, 1)
  let finished = resumed.run(create, bytes => saved = bytes)
  assert_true(finished.complete)
  assert_eq(finished.published, 2)
  assert_eq(stored.length(), 2)
  assert_eq(resumed.receipts().length(), 2)
}

///|
test "failed receipt persistence retains committed state and retries it first" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => {
    "source identity"
  })
  let mut stages = 0
  let mut saves = 0
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    _,
    _,
  ) => {
    stages += 1
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(fn(_) { () }),
      fn() { () },
      fn() { () },
    )
  }
  try
    ignore(
      journal.run(create, _ => {
        saves += 1
        if saves == 3 {
          raise @moonmcap.io_error("snapshot storage full")
        }
      }),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("was published"))
  } noraise {
    _ => fail("snapshot persistence must finish before the next output")
  }
  assert_eq(stages, 1)
  assert_eq(journal.info().published, 1)
  assert_true(journal.info().needs_save)
  let mut retried_snapshot = false
  let finished = journal.run(
    (_, _) => {
      if !retried_snapshot {
        raise @moonmcap.io_error("next stage preceded the snapshot retry")
      }
      stages += 1
      @moonmcap.attachment_export_destination(
        @moonmcap.new_write_sink(fn(_) { () }),
        fn() { () },
        fn() { () },
      )
    },
    _ => retried_snapshot = true,
  )
  assert_true(finished.complete)
  assert_eq(stages, 2)
}

///|
test "journal intent persistence failure aborts before publication and retry saves first" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  let mut stages = 0
  let mut publishes = 0
  let mut aborts = 0
  let mut saves = 0
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    _,
    _,
  ) => {
    stages += 1
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(fn(_) { () }),
      () => publishes += 1,
      () => aborts += 1,
    )
  }
  try
    ignore(
      journal.run(create, _ => {
        saves += 1
        if saves == 2 {
          raise @moonmcap.io_error("cannot persist publication intent")
        }
      }),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("publication intent"))
  } noraise {
    _ => fail("publishing requires a durable intent")
  }
  assert_eq(stages, 1)
  assert_eq(publishes, 0)
  assert_eq(aborts, 1)
  assert_eq(journal.info().published, 0)
  assert_true(journal.info().needs_save)
  let mut saved_retry = false
  let next = journal.run(
    (key, info) => {
      if !saved_retry {
        raise @moonmcap.io_error("retry opened a stage before saving")
      }
      create(key, info)
    },
    _ => saved_retry = true,
    max_files=1,
  )
  assert_eq(next.published, 1)
  assert_eq(publishes, 1)
  assert_eq(stages, 2)
}

///|
test "new journal reconciles publication after completion snapshot save fails" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  let stored : Map[String, Bytes] = Map([])
  let mut stages = 0
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    key,
    _,
  ) => {
    if stored.contains(key) {
      raise @moonmcap.io_error("existing output must never be recreated")
    }
    stages += 1
    let out = @buffer.Buffer::Buffer()
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(bytes => out.write_bytes(bytes[:])),
      () => stored[key] = out.to_bytes(),
      fn() { () },
    )
  }
  let mut durable = b""
  ignore(journal.run(create, bytes => durable = bytes, max_files=1))
  let mut saves = 0
  try
    ignore(
      journal.run(create, bytes => {
        saves += 1
        if saves == 2 {
          raise @moonmcap.io_error("completion snapshot unavailable")
        }
        durable = bytes
      }),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("was published"))
  } noraise {
    _ => fail("second publication must expose its failed receipt save")
  }
  assert_eq(stages, 2)
  assert_eq(stored.length(), 2)
  let mut completed_checks = 0
  let mut pending_checks = 0
  let resumed = @moonmcap.resume_attachment_exports(
    plan,
    _ => "source",
    durable,
    receipt => {
      completed_checks += 1
      stored.contains(receipt.destination)
    },
    reconcile_pending=receipt => {
      pending_checks += 1
      stored.get(receipt.destination) == Some(b"")
    },
  )
  assert_eq(completed_checks, 1)
  assert_eq(pending_checks, 1)
  assert_eq(resumed.info().published, 2)
  assert_true(resumed.info().needs_save)
  assert_false(resumed.info().complete)
  let done = resumed.run(
    (_, _) => raise @moonmcap.io_error("all outputs were already published"),
    bytes => durable = bytes,
  )
  assert_true(done.complete)
  assert_eq(stages, 2)
}

///|
test "unpublished pending intent needs authoritative absence before retry" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  let mut durable = b""
  let mut aborted = 0
  try
    ignore(
      journal.run(
        (_, _) => {
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(fn(_) { () }),
            () => {
              raise @moonmcap.io_error("publish failed before creating target")
            },
            () => aborted += 1,
          )
        },
        bytes => durable = bytes,
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("publish failed"))
  } noraise {
    _ => fail("publication must fail")
  }
  assert_eq(aborted, 1)
  try
    ignore(
      @moonmcap.resume_attachment_exports(plan, _ => "source", durable, _ => {
        true
      }),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("authoritative reconciliation"))
  } noraise {
    _ => fail("ambiguous pending output cannot be silently retried")
  }
  try
    ignore(
      journal.run(
        (_, _) => raise @moonmcap.io_error("unexpected stage creation"),
        fn(_) { () },
      ),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("authoritative reconciliation"))
  } noraise {
    _ => fail("live session must also reconcile an uncertain publication")
  }
  let mut reconciled = 0
  let resumed = @moonmcap.resume_attachment_exports(
    plan,
    _ => "source",
    durable,
    _ => true,
    reconcile_pending=_ => {
      reconciled += 1
      false
    },
  )
  assert_eq(reconciled, 1)
  assert_eq(resumed.info().published, 0)
  assert_true(resumed.info().needs_save)
  let mut saved = false
  let done = resumed.run(
    (_, _) => {
      if !saved {
        raise @moonmcap.io_error("retry did not persist reconciliation first")
      }
      @moonmcap.attachment_export_destination(
        @moonmcap.new_write_sink(fn(_) { () }),
        fn() { () },
        fn() { () },
      )
    },
    _ => saved = true,
  )
  assert_true(done.complete)
}

///|
test "pending journal rejects changed identity and uncertain output content" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "original")
  let mut durable = b""
  try
    ignore(
      journal.run(
        (_, _) => {
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(fn(_) { () }),
            () => raise @moonmcap.io_error("publication outcome unknown"),
            fn() { () },
          )
        },
        bytes => durable = bytes,
      ),
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("publication must be unresolved")
  }
  try
    ignore(
      @moonmcap.resume_attachment_exports(
        plan,
        _ => "changed",
        durable,
        _ => true,
        reconcile_pending=_ => {
          raise @moonmcap.io_error(
            "unexpected reconciliation before source identity check",
          )
        },
      ),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("source or ordered plan changed"))
  } noraise {
    _ => fail("changed identity cannot adopt an output")
  }
  try
    ignore(
      @moonmcap.resume_attachment_exports(
        plan,
        _ => "original",
        durable,
        _ => true,
        reconcile_pending=_ => {
          raise @moonmcap.io_error(
            "pending output content or ownership changed",
          )
        },
      ),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("content or ownership changed"))
  } noraise {
    _ => fail("unknown ownership cannot be interpreted as absence")
  }
}

///|
test "journal accepts version one snapshots at saved completion boundaries" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  ignore(
    journal.run(
      (_, _) => {
        @moonmcap.attachment_export_destination(
          @moonmcap.new_write_sink(fn(_) { () }),
          fn() { () },
          fn() { () },
        )
      },
      fn(_) { () },
      max_files=1,
    ),
  )
  let current = journal.snapshot()
  let old = @buffer.Buffer::Buffer()
  old.write_bytes(b"MCAPXJ1\x00"[:])
  old.write_bytes(current[8:current.length() - 5])
  old.write_uint_le(@moonmcap.crc32(old.to_bytes()))
  let mut verified = 0
  let resumed = @moonmcap.resume_attachment_exports(
    plan,
    _ => "source",
    old.to_bytes(),
    _ => {
      verified += 1
      true
    },
  )
  assert_eq(verified, 1)
  assert_eq(resumed.info().published, 1)
  assert_false(resumed.info().needs_save)
  assert_eq(resumed.snapshot()[:8].to_owned(), b"MCAPXJ2\x00")
}

///|
test "cancellation in intent persistence aborts the stage before publish" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "source")
  let mut saves = 0
  let mut cancelled = false
  let mut published = 0
  let mut aborted = 0
  let mut durable = b""
  try
    ignore(
      journal.run(
        (_, _) => {
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(fn(_) { () }),
            () => published += 1,
            () => aborted += 1,
          )
        },
        bytes => {
          durable = bytes
          saves += 1
          if saves == 2 {
            cancelled = true
          }
        },
        cancelled=() => cancelled,
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("cancel"))
  } noraise {
    _ => fail("cancelled publication intent cannot be committed")
  }
  assert_eq(published, 0)
  assert_eq(aborted, 1)
  assert_eq(journal.info().published, 0)
  assert_true(journal.info().needs_save)
  let resumed = @moonmcap.resume_attachment_exports(
    plan,
    _ => "source",
    durable,
    _ => true,
    reconcile_pending=_ => false,
  )
  assert_eq(resumed.info().published, 0)
  assert_true(resumed.info().needs_save)
}

///|
test "journal rejects corrupted snapshots changed identities and missing outputs" {
  let plan = journal_test_plan()
  let journal = @moonmcap.new_attachment_export_journal(plan, _ => "original")
  ignore(
    journal.run(
      (_, _) => {
        @moonmcap.attachment_export_destination(
          @moonmcap.new_write_sink(fn(_) { () }),
          fn() { () },
          fn() { () },
        )
      },
      fn(_) { () },
      max_files=1,
    ),
  )
  let snapshot = journal.snapshot()
  let corrupted = Bytes::makei(snapshot.length(), i => {
    if i == 15 {
      snapshot[i] ^ 1
    } else {
      snapshot[i]
    }
  })
  try
    ignore(
      @moonmcap.resume_attachment_exports(plan, _ => "original", corrupted, _ => {
        true
      }),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("CRC"))
  } noraise {
    _ => fail("corrupted journal must fail")
  }
  try
    ignore(
      @moonmcap.resume_attachment_exports(plan, _ => "changed", snapshot, _ => {
        true
      }),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("source or ordered plan changed"))
  } noraise {
    _ => fail("changed source identity must fail")
  }
  try
    ignore(
      @moonmcap.resume_attachment_exports(plan, _ => "original", snapshot, _ => {
        false
      }),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("missing or changed"))
  } noraise {
    _ => fail("missing published output must prevent continuation")
  }
}

///|
test "changed destination keys and finite journal budget are checked up front" {
  let plan = journal_test_plan()
  let snapshot = @moonmcap.new_attachment_export_journal(plan, _ => "source").snapshot()
  let changed = batch_test_selection(b"payload").plan_exports(info => {
    "new-\{info.offset}"
  })
  try
    ignore(
      @moonmcap.resume_attachment_exports(changed, _ => "source", snapshot, _ => {
        true
      }),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("source or ordered plan changed"))
  } noraise {
    _ => fail("journal is bound to output identities")
  }
  try
    ignore(
      @moonmcap.new_attachment_export_journal(
        plan,
        _ => "source",
        journal_bytes=32,
      ),
    )
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("budget cannot exclude future receipts")
  }
}
