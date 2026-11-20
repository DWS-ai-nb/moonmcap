///|
extern "js" fn attachment_export_temp() -> String =
  #| () => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const parent = path.resolve("_interop");
  #|   fs.mkdirSync(parent, { recursive: true });
  #|   return fs.mkdtempSync(path.join(parent, "attachment-export-test-"));
  #| }

///|
extern "js" fn attachment_export_cleanup(directory : String) -> Unit =
  #| directory => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   for (const name of fs.readdirSync(directory)) fs.unlinkSync(path.join(directory, name));
  #|   fs.rmdirSync(directory);
  #| }

///|
extern "js" fn attachment_export_count(directory : String) -> Int32 =
  #| directory => process.getBuiltinModule("node:fs").readdirSync(directory).length

///|
extern "js" fn replace_export_directory(directory : String) -> () -> Unit =
  #| directory => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const moved = directory + "-original";
  #|   fs.renameSync(directory, moved);
  #|   fs.mkdirSync(directory);
  #|   return () => {
  #|     fs.rmdirSync(directory);
  #|     fs.renameSync(moved, directory);
  #|   };
  #| }

///|
fn export_selection() -> @mcap.AttachmentSelection raise @mcap.McapError {
  let log = @mcap.empty_log()
  for value in [b"first payload", b"second payload"] {
    log.attachments.push({
      name: "../../same.bin",
      media_type: "application/octet-stream",
      log_time: 9UL,
      create_time: 8UL,
      data: value,
    })
  }
  @mcap.open_reader(@mcap.memory_source(@mcap.write_indexed(log)))
  .attachment_catalog()
  .select()
}

///|
test "binary file export uses physical identities and continuation receipts" {
  let directory = attachment_export_temp()
  defer attachment_export_cleanup(directory)
  let selection = export_selection()
  let plan = @nodeio.attachment_export_plan(
    selection,
    directory,
    prefix="capture",
  )
  let targets = plan.targets()
  assert_eq(targets.length(), 2)
  assert_true(targets[0].0.has_suffix("-\{targets[0].1.offset}.bin"))
  assert_true(targets[0].0 != targets[1].0)
  let published = []
  let first = plan.export_files(max_files=1, on_published=receipt => {
    published.push(receipt.destination)
  })
  assert_eq(first.next_index, Some(1))
  assert_eq(@nodeio.read_file(targets[0].0), b"first payload")
  let remaining = plan.export_files(start_index=1)
  assert_true(remaining.next_index is None)
  assert_eq(@nodeio.read_file(targets[1].0), b"second payload")
  assert_eq(published, [targets[0].0])
  assert_true(first.receipts[0].checksum_verified)
  assert_eq(first.receipts[0].source.name, "../../same.bin")
  assert_eq(attachment_export_count(directory), 2)
}

///|
test "file export preflights later existing destinations before writing a batch" {
  let directory = attachment_export_temp()
  defer attachment_export_cleanup(directory)
  let plan = @nodeio.attachment_export_plan(export_selection(), directory)
  let targets = plan.targets()
  @nodeio.write_atomic_new(targets[1].0, b"existing")
  try ignore(plan.export_files()) catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("already exists"))
  } noraise {
    _ => fail("existing second destination must block the batch")
  }
  assert_eq(attachment_export_count(directory), 1)
  assert_eq(@nodeio.read_file(targets[1].0), b"existing")
}

///|
test "export rejects invalid prefixes and cancellation before creating files" {
  let directory = attachment_export_temp()
  defer attachment_export_cleanup(directory)
  let selection = export_selection()
  for prefix in ["../escape", "", "name.with.extension", "中文"] {
    try
      ignore(@nodeio.attachment_export_plan(selection, directory, prefix~))
    catch {
      @mcap.Invalid(_) => ()
    } noraise {
      _ => fail("unsafe export prefix")
    }
  }
  let plan = @nodeio.attachment_export_plan(selection, directory)
  try ignore(plan.export_files(cancelled=fn() { true })) catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("cancel"))
  } noraise {
    _ => fail("cancelled batch must not create files")
  }
  assert_eq(attachment_export_count(directory), 0)
}

///|
test "export detects a replaced parent before creating staged files" {
  let directory = attachment_export_temp()
  defer attachment_export_cleanup(directory)
  let plan = @nodeio.attachment_export_plan(export_selection(), directory)
  let restore = replace_export_directory(directory)
  defer restore()
  try ignore(plan.export_files()) catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("identity changed"))
  } noraise {
    _ => fail("a reused pathname must not replace directory identity")
  }
  assert_eq(attachment_export_count(directory), 0)
}

///|
test "attachment checksum failure removes only the current staged output" {
  let directory = attachment_export_temp()
  defer attachment_export_cleanup(directory)
  let log = @mcap.empty_log()
  log.attachments.push({
    name: "ordinary",
    media_type: "raw",
    log_time: 1UL,
    create_time: 0UL,
    data: b"payload",
  })
  let bytes = @mcap.write_indexed(log)
  let physical = @mcap.open_reader(@mcap.memory_source(bytes))
  .attachment_catalog()
  .select()
  .items()[0].info()
  let payload = (physical.offset + physical.length - physical.data_size - 4UL).to_int()
  let damaged = Bytes::makei(bytes.length(), i => {
    if i == payload {
      0
    } else {
      bytes[i]
    }
  })
  let selection = @mcap.open_reader(@mcap.memory_source(damaged))
    .attachment_catalog()
    .select()
  let plan = @nodeio.attachment_export_plan(selection, directory)
  try ignore(plan.export_files()) catch {
    @mcap.Invalid(reason) => assert_true(reason.contains("CRC mismatch"))
  } noraise {
    _ => fail("corrupt attachment must not be published")
  }
  assert_eq(attachment_export_count(directory), 0)
}
