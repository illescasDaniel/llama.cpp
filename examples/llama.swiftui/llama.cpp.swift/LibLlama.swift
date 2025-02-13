import Foundation
import llama

enum LlamaError: Error {
	case couldNotLoadModel(path: String)
	case couldNotInitializeContext
	case requiredCacheSizeIsNotBigEnough
	case llamaDecodeFailed
	case failedToEvaluateLlama
	case llamaDecodeFailedDuringPrompt
	case llamaDecodeFailedDuringTextGeneration
}

actor LlamaContext {

	private let model: OpaquePointer
	private let context: OpaquePointer
	private var batch: llama_batch
	private var tokens_list: [llama_token]

	/// This variable is used to store temporarily invalid cchars
	private var temporary_invalid_cchars: [CChar]

	var n_len: Int32 = 64
	var n_cur: Int32 = 0

	var n_decode: Int32 = 0

	init(url: URL) throws {
		let path = url.path(percentEncoded: false)
		llama_backend_init(false)
		var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
		model_params.n_gpu_layers = 0
#endif
		let model = llama_load_model_from_file(path, model_params)
		guard let model else {
			throw LlamaError.couldNotLoadModel(path: path)
		}

		let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))

		var ctx_params = llama_context_default_params()
		ctx_params.seed  = 1234
		ctx_params.n_ctx = 2048
		ctx_params.n_threads       = UInt32(n_threads)
		ctx_params.n_threads_batch = UInt32(n_threads)

		let context = llama_new_context_with_model(model, ctx_params)
		guard let context else {
			throw LlamaError.couldNotInitializeContext
		}

		self.init(model: model, context: context)
	}

	private init(model: OpaquePointer, context: OpaquePointer) {
		self.model = model
		self.context = context
		self.tokens_list = []
		self.batch = llama_batch_init(512, 0, 1)
		self.temporary_invalid_cchars = []
	}

	deinit {
		llama_batch_free(batch)
		llama_free(context)
		llama_free_model(model)
		llama_backend_free()
	}

	func model_info() -> String {
		let capacity = 256
		let buffer = Array<CChar>(unsafeUninitializedCapacity: capacity) { buffer, initializedCount in
			initializedCount = Int(llama_model_desc(model, buffer.baseAddress, capacity)) + 1
			buffer[initializedCount] = CChar(0)
		}
		let description = String(cString: buffer)
		return description
	}

	func get_n_tokens() -> Int32 {
		return batch.n_tokens
	}

	func completion_init(text: String) throws {

		#if DEBUG
		print("attempting to complete \"\(text)\"")
		#endif

		tokens_list = tokenize(text: text, add_bos: true)
		temporary_invalid_cchars = []

		let n_ctx = llama_n_ctx(context)
		let n_kv_req = tokens_list.count + (Int(n_len) - tokens_list.count)

		if n_kv_req > n_ctx {
			throw LlamaError.requiredCacheSizeIsNotBigEnough
		}

#if DEBUG
		for id in tokens_list {
			print(String(cString: token_to_piece(token: id) + [0]))
		}
#endif

		llama_batch_clear(&batch)

		for i1 in 0..<tokens_list.count {
			let i = Int(i1)
			llama_batch_add(&batch, tokens_list[i], Int32(i), [0], false)
		}
		batch.logits[Int(batch.n_tokens) - 1] = 1 // true

		if llama_decode(context, batch) != 0 {
			throw LlamaError.llamaDecodeFailed
		}

		n_cur = batch.n_tokens
	}

	func completion_loop() throws -> String {
		var new_token_id: llama_token = 0

		let n_vocab = llama_n_vocab(model)
		let logits = llama_get_logits_ith(context, batch.n_tokens - 1)

		var candidates = Array<llama_token_data>()
		candidates.reserveCapacity(Int(n_vocab))

		for token_id in 0..<n_vocab {
			candidates.append(llama_token_data(id: token_id, logit: logits![Int(token_id)], p: 0.0))
		}
		candidates.withUnsafeMutableBufferPointer() { buffer in
			var candidates_p = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, sorted: false)

			new_token_id = llama_sample_token_greedy(context, &candidates_p)
		}

		if new_token_id == llama_token_eos(model) || n_cur == n_len {
			let new_token_str = String(cString: temporary_invalid_cchars + [0])
			temporary_invalid_cchars.removeAll()
			return new_token_str
		}

		let new_token_cchars = token_to_piece(token: new_token_id)
		temporary_invalid_cchars.append(contentsOf: new_token_cchars)
		let new_token_str: String
		if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
			temporary_invalid_cchars.removeAll()
			new_token_str = string
		} else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
			// in this case, at least the suffix of the temporary_invalid_cchars can be interpreted as UTF8 string
			let string = String(cString: temporary_invalid_cchars + [0])
			temporary_invalid_cchars.removeAll()
			new_token_str = string
		} else {
			new_token_str = ""
		}
		// tokens_list.append(new_token_id)

		llama_batch_clear(&batch)
		llama_batch_add(&batch, new_token_id, n_cur, [0], true)

		n_decode += 1
		n_cur    += 1

		if llama_decode(context, batch) != 0 {
			throw LlamaError.failedToEvaluateLlama
		}

		return new_token_str
	}

	func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) throws -> String {
		var pp_avg: Double = 0
		var tg_avg: Double = 0

		var pp_std: Double = 0
		var tg_std: Double = 0

		for _ in 0..<nr {
			// bench prompt processing

			llama_batch_clear(&batch)

			let n_tokens = pp

			for i in 0..<n_tokens {
				llama_batch_add(&batch, 0, Int32(i), [0], false)
			}
			batch.logits[Int(batch.n_tokens) - 1] = 1 // true

			llama_kv_cache_clear(context)

			let t_pp_start = ggml_time_us()

			if llama_decode(context, batch) != 0 {
				throw LlamaError.llamaDecodeFailedDuringPrompt
			}

			let t_pp_end = ggml_time_us()

			// bench text generation

			llama_kv_cache_clear(context)

			let t_tg_start = ggml_time_us()

			for i in 0..<tg {
				llama_batch_clear(&batch)

				for j in 0..<pl {
					llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true)
				}

				if llama_decode(context, batch) != 0 {
					throw LlamaError.llamaDecodeFailedDuringTextGeneration
				}
			}

			let t_tg_end = ggml_time_us()

			llama_kv_cache_clear(context)

			let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
			let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

			let speed_pp = Double(pp)    / t_pp
			let speed_tg = Double(pl*tg) / t_tg

			pp_avg += speed_pp
			tg_avg += speed_tg

			pp_std += speed_pp * speed_pp
			tg_std += speed_tg * speed_tg

			#if DEBUG
			print("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
			#endif
		}

		pp_avg /= Double(nr)
		tg_avg /= Double(nr)

		if nr > 1 {
			pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
			tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
		} else {
			pp_std = 0
			tg_std = 0
		}

		let model_desc     = model_info()
		let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0)
		let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9)
		let backend        = "Metal"
		let pp_avg_str     = String(format: "%.2f", pp_avg)
		let tg_avg_str     = String(format: "%.2f", tg_avg)
		let pp_std_str     = String(format: "%.2f", pp_std)
		let tg_std_str     = String(format: "%.2f", tg_std)

		var result = ""

		result += String("| model | size | params | backend | test | t/s |\n")
		result += String("| --- | --- | --- | --- | --- | --- |\n")
		result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
		result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

		return result
	}

	func clear() {
		tokens_list.removeAll()
		temporary_invalid_cchars.removeAll()
		llama_kv_cache_clear(context)
	}

	// MARK: - Private

	private func tokenize(text: String, add_bos: Bool) -> [llama_token] {
		let utf8Count = text.utf8.count
		let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
		let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
		let tokenCount = llama_tokenize(model, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)

		var swiftTokens: [llama_token] = []
		for i in 0..<tokenCount {
			swiftTokens.append(tokens[Int(i)])
		}

		tokens.deallocate()

		return swiftTokens
	}

	/// - note: The result does not contain null-terminator
	private func token_to_piece(token: llama_token) -> [CChar] {
		let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
		result.initialize(repeating: Int8(0), count: 8)
		defer {
			result.deallocate()
		}
		let nTokens = llama_token_to_piece(model, token, result, 8)

		if nTokens < 0 {
			let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
			newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
			defer {
				newResult.deallocate()
			}
			let nNewTokens = llama_token_to_piece(model, token, newResult, -nTokens)
			let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
			return Array(bufferPointer)
		} else {
			let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
			return Array(bufferPointer)
		}
	}

	private func llama_batch_clear(_ batch: inout llama_batch) {
		batch.n_tokens = 0
	}

	private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
		batch.token   [Int(batch.n_tokens)] = id
		batch.pos     [Int(batch.n_tokens)] = pos
		batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
		for i in 0..<seq_ids.count {
			batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
		}
		batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0

		batch.n_tokens += 1
	}
}
