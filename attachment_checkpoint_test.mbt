///|
fn checkpoint_fixture() -> (Bytes, @moonmcap.AttachmentRef) raise @moonmcap.McapError {
  let payload = Bytes::makei(180001, i => (i % 251).to_byte())
  let file = @buffer.Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(b => file.write_bytes(b[:])),
  )
  writer.add_attachment_from(
    @moonmcap.memory_source(payload),
    "capture",
    "application/octet-stream",
  )
  ignore(writer.finish())
  let reader = @moonmcap.open_reader(@moonmcap.memory_source(file.to_bytes()))
  let entries = []
  reader.visit_attachments(a => {
    entries.push(a)
    true
  })
  (payload, entries[0])
}

///|
test "checkpoint resume revalidates exact destination prefix" {
  let (payload, attachment) = checkpoint_fixture()
  let output = @buffer.Buffer()
  let copy = attachment.start_copy(
    @moonmcap.new_write_sink(b => output.write_bytes(b[:])),
  )
  let first = copy.step(max_bytes=80000UL)
  assert_eq(first.copied, 80000UL)
  assert_false(first.complete)
  let checkpoint = copy.checkpoint()
  copy.cancel()
  let resumed = attachment.resume_copy(
    @moonmcap.memory_source(output.to_bytes()),
    b => output.write_bytes(b[:]),
    checkpoint,
  )
  while !resumed.step(max_windows=1).complete {

  }
  assert_true(resumed.progress().crc_verified)
  assert_eq(output.to_bytes(), payload)
  let done = resumed.step()
  assert_eq(done.copied, payload.length().to_uint64())
  assert_true(done.complete)
}

///|
test "checkpoint rejects different binary and corrupted checkpoint" {
  let (_, attachment) = checkpoint_fixture()
  let output = @buffer.Buffer()
  let copy = attachment.start_copy(
    @moonmcap.new_write_sink(b => output.write_bytes(b[:])),
  )
  ignore(copy.step(max_bytes=123UL))
  let saved = copy.checkpoint()
  let prefix = output.to_bytes()
  let bad = Bytes::makei(prefix.length(), i => {
    if i == 5 {
      prefix[i] ^ 1
    } else {
      prefix[i]
    }
  })
  try
    ignore(
      attachment.resume_copy(@moonmcap.memory_source(bad), fn(_) { () }, saved),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("prefix differs"))
  } noraise {
    _ => fail("different destination accepted")
  }
  let corrupt = Bytes::makei(saved.length(), i => {
    if i == 10 {
      saved[i] ^ 1
    } else {
      saved[i]
    }
  })
  try
    ignore(
      attachment.resume_copy(
        @moonmcap.memory_source(prefix),
        fn(_) { () },
        corrupt,
      ),
    )
  catch {
    @moonmcap.Invalid(reason) => assert_true(reason.contains("checkpoint CRC"))
  } noraise {
    _ => fail("corrupted checkpoint accepted")
  }
}

///|
test "copy rejects cancellation observed from a sink callback" {
  let (_, attachment) = checkpoint_fixture()
  let cells : Array[@moonmcap.AttachmentCopy] = []
  let copy = attachment.start_copy(
    @moonmcap.new_write_sink(fn(_) { cells[0].cancel() }),
  )
  cells.push(copy)
  try ignore(copy.step()) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("cancelled copy finished a step")
  }
}

///|
test "staged writer rejects extra or incomplete attachment bytes" {
  for extra in [true, false] {
    let writer = @moonmcap.new_stream_writer(
      @moonmcap.new_write_sink(fn(_) { () }),
    )
    let attachment = writer.begin_attachment("staged", "raw", 1UL)
    try {
      if extra {
        attachment.write(b"too long")
      } else {
        attachment.finish()
      }
    } catch {
      @moonmcap.Invalid(_) => ()
    }
    assert_eq(writer.progress().state, @moonmcap.WriterFailed)
    assert_eq(attachment.remaining(), 1UL)
  }
}
