import { createRoot } from 'react-dom/client'
import KeepAwake from './scene'

// Mounts the Keep Awake demo into the website's #awakeDemo slot.
const el = document.getElementById('awakeDemo')
if (el) createRoot(el).render(<KeepAwake />)
