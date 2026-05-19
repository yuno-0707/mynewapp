import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import router from './routes/index.js';

dotenv.config();

const app = express();
app.use(cors());
app.use(express.json());
app.use('/api', router);

app.get('/health', (_req, res) => res.json({ success: true, data: { status: 'ok' } }));

const port = process.env.PORT || 3001;
app.listen(port, () => console.log(`API running on http://localhost:${port}`));
