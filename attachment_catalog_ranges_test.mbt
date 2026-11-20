///|
test "attachment preview uses checked relative ranges and an independent byte budget" {
  let payload = Bytes::makei(150003, i => (i % 251).to_byte())
  let recording = attachment_test_recording(payload)
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(recording))
  let item = reader.attachment_catalog().select(limit=1).items()[0]
  let before = reader.diagnostics().bytes_read
  assert_eq(item.read_range(65535UL, 20), payload[65535:65555].to_owned())
  assert_true(reader.diagnostics().bytes_read - before < 1024UL)
  assert_eq(item.read_range(payload.length().to_uint64(), 0), b"")
  try ignore(item.read_range(payload.length().to_uint64(), 1)) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("nonempty range cannot start at EOF")
  }
  try ignore(item.read_range(0UL, 40, max_bytes=39)) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("caller slice budget must be checked")
  }
  try ignore(item.read_range(18446744073709551615UL, 1)) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("offset overflow must fail before source I/O")
  }
  let report = item.verify_payload()
  assert_eq(report.payload_bytes, payload.length().to_uint64())
  assert_true(report.crc_verified)
  assert_true(report.bytes_read > report.payload_bytes)
}

///|
test "slice success and whole-payload checksum verification are independent" {
  let original = @moonmcap.write_log(catalog_fixture(), checksums=false)
  let holder = [original]
  let source = @moonmcap.new_read_source(original.length().to_uint64(), (
    offset,
    count,
  ) => holder[0][offset.to_int():offset.to_int() + count].to_owned())
  let reader = @moonmcap.open_reader(source)
  let attachment = reader.attachment_catalog().select(limit=1).items()[0]
  assert_false(attachment.verify_payload().crc_verified)
  assert_eq(attachment.read_range(0UL, 5), b"first")
  let info = attachment.info()
  // Mutate a descriptor byte after the reference was created.
  let name_start = (info.offset + 9UL + 16UL + 4UL).to_int()
  holder[0] = Bytes::makei(original.length(), i => {
    if i == name_start {
      b'x'
    } else {
      original[i]
    }
  })
  try ignore(attachment.read_range(0UL, 1)) catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("changed"))
  } noraise {
    _ => fail("slice must recheck the reference header")
  }
}

///|
test "full attachment verification rejects corruption outside a preview window" {
  let original = @moonmcap.write_indexed(catalog_fixture())
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(original))
  let info = reader.attachment_catalog().select(limit=1).items()[0].info()
  let first = (info.offset + info.length - info.data_size - 4UL).to_int()
  let damaged = Bytes::makei(original.length(), i => {
    if i == first + 4 {
      0
    } else {
      original[i]
    }
  })
  let item = @moonmcap.open_reader(@moonmcap.memory_source(damaged))
    .attachment_catalog()
    .select(limit=1)
    .items()[0]
  assert_eq(item.read_range(0UL, 2), b"fi")
  try ignore(item.verify_payload()) catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("CRC mismatch"))
  } noraise {
    _ => fail("corruption after preview must be detected by full verification")
  }
}

///|
test "mutating selected item arrays cannot change catalogue or selection" {
  let bytes = @moonmcap.write_log({
    ..@moonmcap.empty_log(),
    attachments: [
      {
        log_time: 1UL,
        create_time: 0UL,
        name: "retained",
        media_type: "raw",
        data: b"payload",
      },
    ],
  })
  let catalogue = @moonmcap.open_reader(@moonmcap.memory_source(bytes)).attachment_catalog()
  let selected = catalogue.select()
  let detached = selected.items()
  detached.clear()
  assert_eq(selected.items().length(), 1)
  assert_eq(catalogue.info().records, 1)
  assert_eq(catalogue.select().items().length(), 1)
}
