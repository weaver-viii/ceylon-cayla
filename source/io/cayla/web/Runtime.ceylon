import io.vertx.ceylon.core { Vertx }
import io.vertx.ceylon.core.http { HttpServerRequest,
  HttpServer }
import ceylon.promise { Promise }
import ceylon.collection { HashMap }
import java.util.concurrent { Executors }
import java.lang { Runnable }

"""The application runtime.
   
   The runtime is obtained from the [[Application.start]] method.
   """
shared class Runtime(
  "The application" shared Application application,
  "Vert.x" shared Vertx vertx,
  "The http server" HttpServer server) {
	
	value a = installListener; // Make sure we installed the listener
	
	value executor = Executors.newCachedThreadPool();
	
	"Handles the Vert.x request and dispatch it to a controller"
	shared void handle(HttpServerRequest request) {
		
		// When there is a body, we are invoked by Vert.x before parsing this body
		// so we need to use the Promise<Map<String, {String+}> to get the form
		
		// When there is a form we get it
		Map<String, [String+]> withForm(Map<String, [String+]> form) {
			return form;
		}
		// Otherwise we fail but we just return an empty map
		Map<String, [String+]> withoutForm(Throwable ignore) {
			return emptyMap;
		}
		
		// Dispatch now the request + form in Cayla
		void dispatch(Map<String, [String+]> form) {
			try {
				value result = _handle(request, form);
				switch (result)
				case (is Response) {
					result.send(request.response);
				}
				case (is Promise<Response>) {
					void f(Response response) {
						response.send(request.response);
					}
					void g(Throwable reason) {
						error {
							reason.message;
						}.send(request.response);
					}
					// We propagate the context here
					result.map(f, g);
				}
			} finally {
				// We unset the context here because we need it to be present
				// when a Promise<Response> is returned and we need it to propagate the 
				// context
				current.set(null);
			}
		}
		
		// Chain stuff
		request.formAttributes.map(withForm, withoutForm).completed(dispatch);
	}

	"Handles the Vert.x request and dispatch it to a controller"
	Promise<Response>|Response _handle(HttpServerRequest request, Map<String, [String+]> form) {

		for (match in application.descriptor.resolve(request.path)) {
			
			value desc = match.target;
			
			// Merge parameters : query / form / path
			HashMap<String, [String+]> parameters = HashMap<String, [String+]>();
			for (param in request.params) {
				parameters.put(param.key, param.item);
			}
			for (param in form) {
				value existing = parameters[param.key];
				if (exists existing) {
					parameters.put(param.key, existing.append(param.item));
				} else {
					parameters.put(param.key, param.item);
				}
			}
			for (param in match.params) {
				value existing = parameters[param.key];
				if (exists existing) {
					parameters.put(param.key, existing.withTrailing(param.item));
				} else {
					parameters.put(param.key, [param.item]);
				}
			}
			
			// Todo : make request return ceylon.net.http::Method instead
			value method = request.method;
			if (desc.methods.size == 0 || desc.methods.contains(method)) {
				
				// Attempt to create handler
				Handler handler;
				try {
					handler = match.target.instantiate(*
						parameters.map((String->[String+] element) => element.key->element.item.first)
				  );
				} catch (Exception e) {
					// Somehow should distinguish the kind of error
					// and return an appropriate status code
					// missing parameter    -> 400
					// invocation exception -> 500
					// etc...
					return error {
						"Could not create controller for ``request.path`` with ``parameters``: ``e.message``";
					};
				}

				//
				if (match.target.blocking) {
					// Create a promise that will run on Vert.x context
					value promise = vertx.executionContext.deferred<Response>();
					object task satisfies Runnable {
						shared actual void run() {
							value result = execute(request, handler, parameters);
							promise.fulfill(result);
						}
					}
					executor.execute(task);
					return promise.promise;
				} else {
					return execute(request, handler, parameters);
				}
			}
		}		
		return notFound {
			"Could not match a controller for ``request.path``";
		};
	}
	
	Response|Promise<Response> execute(
		HttpServerRequest request,
		Handler handler,
		Map<String, [String+]> params) {
		value context = RequestContext(this, params, request);
		current.set(context);
		try {
			return handler.invoke(context);
		}
		catch (Exception e) {
			return error {
				e.message;
			};
		}
	}
	
	"Stop the application"
	shared Promise<Anything> stop() {
		value done = server.close();
		executor.shutdown();
		vertx.stop();
		return done;
	}
}

