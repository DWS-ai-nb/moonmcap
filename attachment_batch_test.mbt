///|
fn batch_test_selection(
  payload : Bytes,
) -> @moonmcap.AttachmentSelection raise @moonmcap.McapError {
  let bytes = @moonmcap.write_log({
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 1UL,
        create_time: 0UL,
        name: "same.bin",
        media_type: "application/octet-stream",
        data: payload,
      },
      {
        log_time: 2UL,
        create_time: 1UL,
        name: "same.bin",
        media_type: "application/octet-stream",
        data: b"",
      },
    ],
  })
  @moonmcap.open_reader(@moonmcap.memory_source(bytes))
  .attachment_catalog(verify_coverage=true)
  .select()
}

///|
test "batch preflights duplicate destination identities before creating stages" {
  let selection = batch_test_selection(b"first")
  try ignore(selection.plan_exports(info => info.name)) catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("duplicate attachment export destination"))
  } noraise {
    _ =>
      fail("same names require caller-selected unique destination identities")
  }
  let plan = selection.plan_exports(info => "\{info.offset}-\{info.name}")
  assert_eq(plan.info().records, 2)
  assert_eq(plan.info().payload_bytes, 5UL)
  assert_true(plan.targets()[0].0 != plan.targets()[1].0)
}

///|
test "batch continuation publishes each output once with verified receipts" {
  let plan = batch_test_selection(b"payload").plan_exports(info => {
    info.offset.to_string()
  })
  let committed : Map[String, Bytes] = Map([])
  let seen = []
  let mut opened = 0
  let mut aborted = 0
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    key,
    _,
  ) => {
    opened += 1
    let staged = @buffer.Buffer::Buffer()
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(bytes => staged.write_bytes(bytes[:])),
      () => committed[key] = staged.to_bytes(),
      () => aborted += 1,
    )
  }
  let first = plan.export_files(create, max_files=1, on_published=receipt => {
    seen.push(receipt.destination)
  })
  assert_eq(first.next_index, Some(1))
  assert_eq(first.payload_bytes, 7UL)
  assert_true(first.receipts[0].checksum_verified)
  let next = first.next_index.unwrap()
  let last = plan.export_files(create, start_index=next, on_published=receipt => {
    seen.push(receipt.destination)
  })
  assert_eq(last.next_index, None)
  assert_eq(last.payload_bytes, 0UL)
  assert_eq(committed[seen[0]], b"payload")
  assert_eq(committed[seen[1]], b"")
  assert_eq(opened, 2)
  assert_eq(aborted, 0)
}

///|
test "cancellation during one output aborts its stage and stops later outputs" {
  let plan = batch_test_selection(Bytes::make(150003, 4)).plan_exports(info => {
    info.offset.to_string()
  })
  let mut stop = false
  let mut opened = 0
  let mut published = 0
  let mut aborted = 0
  try
    ignore(
      plan.export_files(
        (_, _) => {
          opened += 1
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(_ => stop = true),
            () => published += 1,
            () => aborted += 1,
          )
        },
        cancelled=() => stop,
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("cancelled"))
  } noraise {
    _ => fail("cancelled export should return an error")
  }
  assert_eq(opened, 1)
  assert_eq(published, 0)
  assert_eq(aborted, 1)
}

///|
test "publish failure aborts staging exactly once" {
  let plan = batch_test_selection(b"payload").plan_exports(info => {
    info.offset.to_string()
  })
  let mut aborted = 0
  try
    ignore(
      plan.export_files((_, _) => {
        @moonmcap.attachment_export_destination(
          @moonmcap.new_write_sink(fn(_) { () }),
          () => raise @moonmcap.io_error("publish failed"),
          () => aborted += 1,
        )
      }),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("publish failed"))
  } noraise {
    _ => fail("publication errors must propagate")
  }
  assert_eq(aborted, 1)
}

///|
test "receipt failure reports already published output without aborting it" {
  let plan = batch_test_selection(b"payload").plan_exports(info => {
    info.offset.to_string()
  })
  let mut published = 0
  let mut aborted = 0
  try
    ignore(
      plan.export_files(
        (_, _) => {
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(fn(_) { () }),
            () => published += 1,
            () => aborted += 1,
          )
        },
        on_published=_ => raise @moonmcap.io_error("receipt store full"),
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => {
      assert_true(reason.contains("was published"))
      assert_true(reason.contains("receipt store full"))
    }
  } noraise {
    _ => fail("receipt persistence errors should identify committed output")
  }
  assert_eq(published, 1)
  assert_eq(aborted, 0)
}

///|
test "batch key and continuation budgets fail before creating destinations" {
  let selection = batch_test_selection(b"payload")
  try
    ignore(selection.plan_exports(info => info.offset.to_string(), key_bytes=0))
  catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("output key budget must be enforced")
  }
  let plan = selection.plan_exports(info => info.offset.to_string())
  let mut opened = false
  try
    ignore(
      plan.export_files(
        (_, _) => {
          opened = true
          raise @moonmcap.io_error("unexpected create")
        },
        start_index=3,
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("continuation"))
  } noraise {
    _ => fail("invalid continuation must fail")
  }
  assert_false(opened)
}

///|
test "later attachment checksum failure leaves earlier committed receipt intact" {
  let bytes = @moonmcap.write_log({
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 1UL,
        create_time: 0UL,
        name: "first",
        media_type: "raw",
        data: b"safe",
      },
      {
        log_time: 2UL,
        create_time: 0UL,
        name: "second",
        media_type: "raw",
        data: b"bad",
      },
    ],
  })
  let original = @moonmcap.open_reader(@moonmcap.memory_source(bytes))
    .attachment_catalog()
    .select()
    .items()
  let second = original[1].info()
  let payload = (second.offset + second.length - second.data_size - 4UL).to_int()
  let corrupted = Bytes::makei(bytes.length(), i => {
    if i == payload {
      0
    } else {
      bytes[i]
    }
  })
  let plan = @moonmcap.open_reader(@moonmcap.memory_source(corrupted))
    .attachment_catalog()
    .select()
    .plan_exports(info => info.name)
  let receipts = []
  let published = []
  let aborted = []
  try
    ignore(
      plan.export_files(
        (key, _) => {
          @moonmcap.attachment_export_destination(
            @moonmcap.new_write_sink(fn(_) { () }),
            () => published.push(key),
            () => aborted.push(key),
          )
        },
        on_published=receipt => receipts.push(receipt.destination),
      ),
    )
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("attachment CRC mismatch"))
  } noraise {
    _ => fail("the second attachment checksum must be checked")
  }
  assert_eq(published, ["first"])
  assert_eq(receipts, ["first"])
  assert_eq(aborted, ["second"])
}

///|
test "one export plan rejects callback reentry and remains reusable afterward" {
  let plan = batch_test_selection(b"payload").plan_exports(info => {
    info.offset.to_string()
  })
  let mut rejected = false
  let create : (String, @moonmcap.AttachmentIndex) -> @moonmcap.AttachmentExportDestination raise @moonmcap.McapError = (
    _,
    _,
  ) => {
    ignore(
      plan.export_files((_, _) => {
        raise @moonmcap.io_error("unexpected nested stage")
      }),
    ) catch {
      @moonmcap.Invalid(reason) =>
        rejected = reason.contains("already executing")
    }
    @moonmcap.attachment_export_destination(
      @moonmcap.new_write_sink(fn(_) { () }),
      fn() { () },
      fn() { () },
    )
  }
  let completed = plan.export_files(create)
  assert_true(rejected)
  assert_eq(completed.receipts.length(), 2)
  assert_eq(plan.export_files(create, start_index=2).receipts.length(), 0)
}
