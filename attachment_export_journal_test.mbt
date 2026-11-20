///|
fn journal_test_plan() -> @moonmcap.AttachmentExportPlan raise @moonmcap.McapError {
  batch_test_selection(b"payload").plan_exports(info => info.offset.to_string())
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
        if saves == 2 {
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
