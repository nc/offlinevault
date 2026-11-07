class OvsyncError(Exception):
    exit_code = 1


class LicenceNeeded(OvsyncError):
    exit_code = 2


class VerificationFailed(OvsyncError):
    exit_code = 3


class NetworkError(OvsyncError):
    exit_code = 4
