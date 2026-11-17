import IronPetObjC

/// Runs `body` and turns an Objective-C exception raised inside it into a thrown Swift error.
func catchingObjCException<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    var raised: NSError?
    let ok = IronPetCatchException({ result = Result(catching: body) }, &raised)
    if !ok, let raised { throw raised }
    return try result!.get()
}
