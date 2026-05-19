export function ok(res, data = {}) {
  return res.json({ success: true, data });
}

export function fail(res, message = 'Unexpected error', code = 'INTERNAL_ERROR', status = 500) {
  return res.status(status).json({
    success: false,
    error: { message, code }
  });
}
