///|
fn catalog_fixture() -> @moonmcap.Log {
  let log = @moonmcap.empty_log()
  log.attachments.push({
    name: "shared",
    media_type: "application/a",
    log_time: 20UL,
    create_time: 19UL,
    data: b"first",
  })
  log.attachments.push({
    name: "shared",
    media_type: "application/b",
    log_time: 30UL,
    create_time: 0UL,
    data: b"",
  })
  log.attachments.push({
    name: "other",
    media_type: "application/a",
    log_time: 20UL,
    create_time: 0UL,
    data: b"third",
  })
  log
}

///|
fn catalog_edit_record(
  bytes : Bytes,
  opcode : Byte,
  edit : (Bytes) -> Bytes raise @moonmcap.McapError,
) -> Bytes raise @moonmcap.McapError {
  let target = @moonmcap.scan_file(bytes)
    .iter()
    .find_first(record => record.opcode == opcode)
  guard target is Some(record) else {
    raise @moonmcap.io_error("test record missing")
  }
  let body = edit(record.body)
  guard body.length() == record.body.length() else {
    raise @moonmcap.io_error("test mutation changed record size")
  }
  let patched = bytes[:record.offset].to_owned() +
    @moonmcap.frame(opcode, body) +
    bytes[record.offset + 9 + record.body.length():].to_owned()
  // Summary and data checksums are absent on the mutated fixture so the
  // catalogue's header/index comparison is exercised independently.
  let footer_crc = patched.length() - 12
  Bytes::makei(patched.length(), i => {
    if i >= footer_crc && i < footer_crc + 4 {
      0
    } else {
      patched[i]
    }
  })
}

///|
test "attachment catalogue uses complete index and exposes coverage evidence" {
  let bytes = @moonmcap.write_indexed(catalog_fixture())
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(bytes))
  let catalogue = reader.attachment_catalog()
  assert_true(catalogue.info().used_index)
  assert_false(catalogue.info().coverage_checked)
  assert_eq(catalogue.info().records, 3)
  assert_eq(catalogue.info().payload_bytes, 10UL)
  let selected = catalogue.select()
  let items = selected.items()
  assert_eq(items.map(item => item.info().name), ["shared", "shared", "other"])
  assert_true(items[0].info().offset < items[1].info().offset)
  let found = catalogue.find(items[1].info().offset)
  assert_true(found is Some(_))
  assert_true(catalogue.find(items[1].info().offset + 1UL) is None)
  let evidence = reader.attachment_catalog(verify_coverage=true).info()
  assert_false(evidence.used_index)
  assert_true(evidence.coverage_checked)
  assert_eq(evidence.payload_bytes, catalogue.info().payload_bytes)
  let verified = selected.verify()
  assert_eq(verified.records, 3)
  assert_eq(verified.checksums_verified, 3)
}

///|
test "attachment selection combines filters and budgets without ambiguity" {
  let bytes = @moonmcap.write_indexed(catalog_fixture())
  let catalogue = @moonmcap.open_reader(@moonmcap.memory_source(bytes)).attachment_catalog()
  let query = {
    ..@moonmcap.all_attachments(),
    names: ["shared"],
    start_time: 20UL,
    end_time: 30UL,
  }
  let first = catalogue.select(query~, limit=1)
  assert_eq(first.matching_records, 2)
  assert_eq(first.selected_bytes, 5UL)
  assert_eq(first.next_offset, Some(1))
  let last = catalogue.select(query~, offset=1, limit=1, payload_bytes=0UL)
  assert_eq(last.items()[0].info().media_type, "application/b")
  assert_eq(last.next_offset, None)
  let exact = catalogue.select(query={
    ..query,
    media_types: ["application/a"],
    end_time: 20UL,
  })
  assert_eq(exact.items().length(), 1)
  try ignore(catalogue.select(query~, payload_bytes=4UL)) catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("payload budget"))
  } noraise {
    _ => fail("selected bytes must obey the independent payload budget")
  }
  try ignore(catalogue.select(query={ ..query, start_time: 31UL, })) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("inverted Attachment time range")
  }
}

///|
test "catalogue scans when statistics attachment count disagrees" {
  let bytes = @moonmcap.write_indexed(catalog_fixture())
  let modified = catalog_edit_record(bytes, 0x0b, body => {
    let stats = @moonmcap.decode_file_statistics(body)
    @moonmcap.encode_file_statistics({ ..stats, attachment_count: 4U, })
  })
  let result = @moonmcap.open_reader(@moonmcap.memory_source(modified)).attachment_catalog()
  assert_false(result.info().used_index)
  assert_true(result.info().coverage_checked)
  assert_eq(result.info().records, 3)
}

///|
test "catalogue rejects conflicting index metadata and overlapping ranges" {
  let bytes = @moonmcap.write_indexed(catalog_fixture())
  let changed_name = catalog_edit_record(bytes, 0x0a, body => {
    let index = @moonmcap.decode_attachment_index(body)
    @moonmcap.encode_attachment_index({ ..index, name: "edited", })
  })
  try
    ignore(
      @moonmcap.open_reader(@moonmcap.memory_source(changed_name)).attachment_catalog(),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("disagrees"))
  } noraise {
    _ => fail("header and index names differ")
  }
  let overlap = catalog_edit_record(bytes, 0x0a, body => {
    let index = @moonmcap.decode_attachment_index(body)
    @moonmcap.encode_attachment_index({ ..index, length: index.length + 1UL, })
  })
  try
    ignore(
      @moonmcap.open_reader(@moonmcap.memory_source(overlap)).attachment_catalog(),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("overlapping"))
  } noraise {
    _ => fail("AttachmentIndex spans overlap")
  }
}

///|
test "sequential and empty catalogue preserve checksum absence" {
  let bytes = @moonmcap.write_log(catalog_fixture(), checksums=false)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(bytes))
  let catalogue = reader.attachment_catalog()
  assert_true(catalogue.info().coverage_checked)
  assert_false(catalogue.info().used_index)
  let verified = catalogue.select().verify()
  assert_eq(verified.checksums_verified, 0)
  assert_eq(verified.checksums_absent, 3)
  let empty = @moonmcap.open_reader(
    @moonmcap.memory_source(@moonmcap.write_indexed(@moonmcap.empty_log())),
  ).attachment_catalog()
  assert_eq(empty.info().records, 0)
  assert_true(empty.select().items().is_empty())
}

///|
test "catalogue respects descriptor budgets cancellation and large payload streaming" {
  let source = @moonmcap.memory_source(
    attachment_test_recording(Bytes::make(150003, 7)),
  )
  let reader = @moonmcap.open_reader(source, limits=attachment_test_limits)
  let indexed = reader.attachment_catalog()
  assert_eq(indexed.info().records, 2)
  assert_eq(indexed.info().payload_bytes, 150003UL)
  assert_true(indexed.info().bytes_read < 4096UL)
  try ignore(reader.attachment_catalog(descriptor_bytes=1)) catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("descriptor budget"))
  } noraise {
    _ => fail("descriptor retention must obey budget")
  }
  try ignore(reader.attachment_catalog(cancelled=fn() { true })) catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("cancel"))
  } noraise {
    _ => fail("cancelled catalogue should reject reads")
  }
  let output = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(bytes => output.write_bytes(bytes[:])),
    limits=attachment_test_limits,
    options=attachment_test_options,
  )
  indexed.select().copy_into(writer)
  ignore(writer.finish())
  let copy = @moonmcap.open_reader(
    @moonmcap.memory_source(output.to_bytes()),
    limits=attachment_test_limits,
  )
  assert_eq(copy.attachment_catalog().select().verify().records, 2)
}

///|
test "catalogue can skip a payload whose length exceeds Int32" {
  let payload_size = 2147483648UL + 19UL
  let prefix = @buffer.Buffer::Buffer()
  prefix.write_bytes(@moonmcap.magic()[:])
  prefix.write_bytes(
    @moonmcap.frame(
      0x01,
      @moonmcap.encode_header({ profile: "", library: "sparse boundary test", }),
    )[:],
  )
  let attachment_at = prefix.length().to_uint64()
  prefix.write_byte(0x09)
  prefix.write_uint64_le(payload_size + 36UL)
  prefix.write_uint64_le(10UL)
  prefix.write_uint64_le(0UL)
  prefix.write_uint_le(0U)
  prefix.write_uint_le(0U)
  prefix.write_uint64_le(payload_size)
  let first = prefix.to_bytes()
  let tail_at = first.length().to_uint64() + payload_size
  let tail = @buffer.Buffer::Buffer()
  tail.write_uint_le(0U)
  tail.write_bytes(@moonmcap.frame(0x0f, b"\x00\x00\x00\x00")[:])
  tail.write_bytes(
    @moonmcap.frame(
      0x02,
      @moonmcap.encode_footer({
        summary_start: 0UL,
        summary_offset_start: 0UL,
        summary_crc: 0U,
      }),
    )[:],
  )
  tail.write_bytes(@moonmcap.magic()[:])
  let last = tail.to_bytes()
  let source = @moonmcap.new_read_source(tail_at + last.length().to_uint64(), (
    offset,
    length,
  ) => {
    if offset < first.length().to_uint64() &&
      length.to_uint64() <= first.length().to_uint64() - offset {
      first[offset.to_int():offset.to_int() + length].to_owned()
    } else if offset >= tail_at &&
      length.to_uint64() <= last.length().to_uint64() - (offset - tail_at) {
      let at = (offset - tail_at).to_int()
      last[at:at + length].to_owned()
    } else {
      raise @moonmcap.io_error("catalogue attempted to read sparse payload")
    }
  })
  let result = @moonmcap.open_reader(source).attachment_catalog()
  assert_eq(result.info().records, 1)
  assert_eq(result.info().payload_bytes, payload_size)
  assert_true(result.info().coverage_checked)
  let attachment = result.select(payload_bytes=payload_size).items()[0]
  assert_eq(attachment.info().offset, attachment_at)
  assert_eq(attachment.info().data_size, payload_size)
}
