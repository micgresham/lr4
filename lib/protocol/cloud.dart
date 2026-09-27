// Whisker's stock cloud settings, for putting a robot back on the official
// service without the Whisker app.
//
// These are not secrets and not per-robot. The AWS IoT endpoint is Whisker's
// own, recovered by whiskerless from a decoded capture of the Whisker app's
// BLE onboarding (docs/devices/litter-robot-4/provisioning/app-onboarding-capture.md);
// the robot itself has no way to report it back. The topics embed the serial
// printed on the robot's label. The root CA is Amazon's public Root CA 1,
// whose 1188-byte PEM matches the 1188 bytes the app was captured writing.
//
// What this canNOT restore is the robot's own certificate and key. Nothing can
// read those back, so they must still be the factory pair for a cloud restore
// to authenticate. Provisioning leaves them alone unless you deliberately
// write your own.

/// Whisker's AWS IoT endpoint (ATS), as written by the Whisker app.
const whiskerCloudHost = 'a2wz9c6y6mikoy-ats.iot.us-east-1.amazonaws.com';

/// Amazon Root CA 1 (SHA-256 8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e),
/// downloaded from https://www.amazontrust.com/repository/AmazonRootCA1.pem
const amazonRootCa1 =
    '-----BEGIN CERTIFICATE-----\n'
    'MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF\n'
    'ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6\n'
    'b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL\n'
    'MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv\n'
    'b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj\n'
    'ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM\n'
    '9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw\n'
    'IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6\n'
    'VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L\n'
    '93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm\n'
    'jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC\n'
    'AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA\n'
    'A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI\n'
    'U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs\n'
    'N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv\n'
    'o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU\n'
    '5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy\n'
    'rqXRfboQnoZsG4q5WTP468SQvvG5\n'
    '-----END CERTIFICATE-----\n';
