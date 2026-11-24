// Endereços do Supabase da Dra. Nada aqui é segredo: a chave pública só
// serve para o login, e a API não devolve nada sem a conta dela com o código
// de dois fatores.
export const SUPABASE_URL = "https://wyubbsqurhqrztpexkdc.supabase.co";
export const CHAVE_PUBLICA = "sb_publishable_coUc7mJfIfACTgb9CvQKfw_A_oxEgBj";
export const API = `${SUPABASE_URL}/functions/v1/painel`;
/** Botões de lançar (recebimento, despesa, estoque) pelo site. */
export const LANCAR_PELO_SITE = true;
