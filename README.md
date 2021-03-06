This package contains code to generate and verify the RLWE challenges. It also contains one of the protobuf files needed to read the serialized challenges. The proto file can be used with any language with an implementation of protocol-buffers.

The library only contains files generated by hprotoc; the executable contains the code to generate, suppress, and verify challenges.

Suppression can be done offline by placing the relevant NIST beacon files in the challenge directory created in the generation process. For example,

```
bash$ .stack-work/install/x86_64-osx/lts-8.2/8.0.2/bin/rlwe-challenges generate --challenge-dir mychallengedir --init-beacon 1533759960
# Generation is done
# ...
# Later in time, we have downloaded the NIST beacon file
bash$ cp ~/Downloads/1533759960.xml ./mychallengedir/epoch-1533759960.xml
bash$ .stack-work/install/x86_64-osx/lts-8.2/8.0.2/bin/rlwe-challenges suppress --challenge-dir mychallengedir
```
