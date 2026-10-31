# TextKit SDKs

Official clients and CLI for [TextKit](https://jointextkit.com): SMS, phone verification and phone numbers.

```bash
npm install jointextkit
```

```js
import { TextKit } from 'jointextkit';

const sms = new TextKit(process.env.TEXTKIT_API_KEY);
await sms.messages.send({ to: '+15005550006', body: 'Your table is ready.' });
```

Test keys are free. Get one at [jointextkit.com/console](https://jointextkit.com/console).

| Language | Package | Path |
|---|---|---|
| Node and CLI | `jointextkit` | [packages/textkit](packages/textkit) |
| Python | `jointextkit` | [packages/textkit-python](packages/textkit-python) |
| Go | source | [packages/textkit-go](packages/textkit-go) |
| PHP | source | [packages/textkit-php](packages/textkit-php) |
| Swift | source | [packages/textkit-swift](packages/textkit-swift) |
| Kotlin | source | [packages/textkit-kotlin](packages/textkit-kotlin) |

The API spec is [openapi.yaml](openapi.yaml). Docs are at [jointextkit.com/docs](https://jointextkit.com/docs).

MIT licensed.
